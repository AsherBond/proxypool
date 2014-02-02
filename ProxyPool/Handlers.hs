{-# LANGUAGE OverloadedStrings, LambdaCase, BangPatterns, DeriveDataTypeable, MultiWayIf #-}
module ProxyPool.Handlers (
    initaliseGlobal
  , initaliseClient
  , handleClient
  , finaliseClient

  , initaliseServer
  , handleServer
  , finaliseServer

  , handleDB

  , GlobalState
  , ServerSettings(..)

  , KillClientException
) where

import ProxyPool.Stratum
import ProxyPool.Mining

import System.IO (Handle, hClose)
import System.Log.Logger
import System.Timeout

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((&&&))

import Control.Monad (forever, join, when, unless, mzero)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Either

import Control.Exception hiding (handle)

import Control.Concurrent (threadDelay)
import Control.Concurrent.Chan
import Control.Concurrent.Async

import Control.Concurrent.MVar

import Data.IORef
import Data.Aeson
import Data.Word
import Data.Typeable
import qualified Data.Vector as V

import Data.Monoid ((<>))

import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.Encoding as TL

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL

import qualified Database.Redis as R

data HandlerState
    = HandlerState { _handle   :: Handle
                   , _children :: IORef [Async ()]
                   }

data ServerState
    = ServerState { s_handler    :: HandlerState
                  , s_writerChan :: Chan B.ByteString
                  }

data ClientState
    = ClientState { c_handler          :: HandlerState
                  , c_writerChan       :: Chan B.ByteString
                  , c_job              :: IORef Job
                  , c_difficulty       :: IORef Double
                  -- | Number of shares submitted by the client since last vardiff retarget
                  , c_lastShares       :: IORef Int
                  -- | Number of dead shares submitted by the client since last vardiff retarget
                  , c_lastSharesDead   :: IORef Int
                  -- | Uniquely identifies this client
                  , c_id               :: !Integer
                  -- | Hostname of the client
                  , c_host             :: String
                  }

data ServerSettings
    = ServerSettings { _serverName          :: T.Text
                     -- | Host name of the upstream pool
                     , _upstreamHost        :: T.Text
                     -- | Port of the upstream pool
                     , _upstreamPort        :: Word16
                     -- | Port to listen to for workers
                     , _localPort           :: Word16
                     -- | Username to login to upstream pool
                     , _username            :: T.Text
                     -- | Password to login to upstream pool
                     , _password            :: T.Text
                     -- | Using redis to pubsub shares
                     , _redisHost           :: T.Text
                     -- | Authentication for redis
                     , _redisAuth           :: Maybe T.Text
                     -- | The redis channel to publish to
                     , _redisChanName       :: T.Text
                     -- | The byte prepended to the public key, used to verify miner addresses, 0 for Bitcoin, 30 for Dogecoin
                     , _publickeyByte       :: Word8
                     -- | Size of the new en2
                     , _extraNonce2Size     :: Int
                     -- | Size of the new en3
                     , _extraNonce3Size     :: Int
                     -- | Time (s) between vardiff updates
                     , _vardiffRetargetTime :: Int
                     -- | Target shares retarget time
                     , _vardiffTarget       :: Int
                     -- | Allow variances to be within this range
                     , _vardiffAllowance    :: Double
                     -- | Minimum allowable difficulty
                     , _vardiffMin          :: Double
                     -- | How many minutes does ban take to expire
                     , _banExpiry           :: Int
                     } deriving (Show)

instance FromJSON ServerSettings where
    parseJSON (Object v) = ServerSettings             <$>
                           v .: "serverName"          <*>
                           v .: "upstreamHost"        <*>
                           v .: "upstreamPort"        <*>
                           v .: "localPort"           <*>
                           v .: "username"            <*>
                           v .: "password"            <*>
                           v .: "redisHost"           <*>
                           v .: "redisAuth"           <*>
                           v .: "redisChanName"       <*>
                           v .: "publicKeyByte"       <*>
                           v .: "extraNonce2Size"     <*>
                           v .: "extraNonce3Size"     <*>
                           v .: "vardiffRetargetTime" <*>
                           v .: "vardiffTarget"       <*>
                           v .: "vardiffAllowance"    <*>
                           v .: "vardiffMin"          <*>
                           v .: "banExpiry"

    parseJSON _          = mzero

data GlobalState
    = GlobalState { _clientCounter  :: IORef Integer
                  , _nonceCounter   :: IORef Integer
                  , _matchCounter   :: IORef Integer
                  , _upstreamDiff   :: IORef Double
                  , _currentWork    :: IORef Work
                  -- | Channel for notifications
                  , _notifyChan     :: Chan StratumResponse
                  -- | Channel for upstream requests
                  , _upstreamChan   :: Chan Request
                  -- | Channel for share logging broadcasts
                  , _shareChan      :: Chan Share
                  -- | Channel used to ban hosts
                  , _banChan        :: Chan String
                  -- | Channel used to request checks on the host
                  , _checkChan      :: Chan (String, Bool -> IO ())
                  , _settings       :: ServerSettings
                  }

data Job
    = Job { j_jobID  :: {-# UNPACK #-} !T.Text
          , j_nonce1 :: {-# UNPACK #-} !(Integer, Int)
          , j_nonce2 :: {-# UNPACK #-} !(Integer, Int)
          }
    deriving (Show)

data Share
    = Share { sh_submitter  :: {-# UNPACK #-} !T.Text
            , sh_difficulty :: {-# UNPACK #-} !Double
            , sh_server     :: {-# UNPACK #-} !T.Text
            , sh_valid      ::                !Bool
            }
    deriving (Show, Typeable)

instance ToJSON Share where
    toJSON (Share sub diff srv valid) = object [ "sub"   .= sub
                                               , "diff"  .= diff
                                               , "srv"   .= srv
                                               , "valid" .= valid
                                               ]

-- | Used to deliberately terminate the client thread
data KillClientException = KillClientException { _reason :: String } deriving (Show, Typeable)

instance Exception KillClientException

-- | Increments an IORef counter
incr :: IORef Integer -> IO Integer
incr counter = atomicModifyIORef' counter $ join (&&&) (1+)

initaliseGlobal :: ServerSettings -> IO GlobalState
initaliseGlobal settings = GlobalState        <$>
                           newIORef 0         <*>
                           newIORef 0         <*>
                           newIORef 0         <*>
                           newIORef 0.0       <*>
                           newIORef emptyWork <*>
                           newChan            <*>
                           newChan            <*>
                           newChan            <*>
                           newChan            <*>
                           newChan            <*>
                           return settings

initaliseHandler :: Handle -> IO HandlerState
initaliseHandler handle = HandlerState <$> return handle <*> newIORef []

finaliseHandler :: HandlerState -> IO ()
finaliseHandler state = do
    hClose $ _handle state
    readIORef (_children state) >>= mapM_ cancel

-- | Initalises client state
initaliseClient :: Handle -> String -> GlobalState -> IO ClientState
initaliseClient handle host global = ClientState                   <$>
                                     initaliseHandler handle       <*>
                                     newChan                       <*>
                                     newIORef (Job "" (0,0) (0,0)) <*>
                                     newIORef 0.000488             <*>
                                     newIORef 0                    <*>
                                     newIORef 0                    <*>
                                     incr (_clientCounter global)  <*>
                                     return host

-- | Record child threads as well as ensuring child thread death triggers an exception on the parent
linkChild :: HandlerState -> Async () -> IO ()
linkChild handler asy = modifyIORef' (_children $ handler) (asy:) >> link asy

process :: (Monad m, MonadIO m, FromJSON a) => Handle -> (Maybe a -> EitherT b m ()) -> m b
process handle f = do
    result <- runEitherT $ forever $ do
        line <- liftIO $ B.hGetLine $ handle
        f $ decodeStrict line

    return $ either id (error "impossible") result

finish :: Monad m => e -> EitherT e m a
finish = left

continue :: Monad m => EitherT e m ()
continue = return ()

handleClient :: GlobalState -> ClientState -> IO ()
handleClient global local = do
    let
        -- | Write server response
        writeResponse :: Value -> StratumResponse -> IO ()
        writeResponse rid resp = writeResponseRaw $ BL.toStrict . encode $ Response rid resp

        writeResponseRaw :: B.ByteString -> IO ()
        writeResponseRaw = writeChan (c_writerChan local)

        en2Size :: Int
        en2Size = _extraNonce2Size . _settings $ global

        nextNonce :: IO Integer
        nextNonce = atomicModifyIORef' (_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))

        packEn2 :: Integer -> T.Text
        packEn2 nonce = toHex $ BL.toStrict $ B.toLazyByteString $ packIntLE nonce en2Size

        handle :: Handle
        handle = _handle . c_handler $ local

        -- | Send request to upstream, taking the request and a callback
        upstreamRequest :: StratumRequest -> IO ()
        upstreamRequest request = do
            -- generate a new request ID
            rid <- incr $ _matchCounter global
            -- send request to the upstream listener
            writeChan (_upstreamChan global) $ Request (Number . fromInteger $ rid) request

    -- thread to sequence writes
    (linkChild (c_handler local) =<<) . async . forever $ do
        line <- readChan (c_writerChan local)
        B8.hPutStrLn handle line

    -- check if the IP is banned
    banned <- liftIO $ do
        waiter <- newEmptyMVar
        writeChan (_checkChan global) (c_host local, putMVar waiter)
        takeMVar waiter

    -- wait for mining.subscription call
    initalised <- timeout 30 $ process handle $ \case
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ _extraNonce3Size . _settings $ global
            finish ()
        _ -> continue

    maybe (throwIO $ KillClientException "Took too long to initalise") (const $ return ()) initalised

    -- proxy server notifications
    (linkChild (c_handler local) =<<) . async $ unless banned $ do
        -- duplicate server notification channel
        localNotifyChan <- dupChan (_notifyChan global)

        forever $ readChan localNotifyChan >>= \case
            -- coinbase1 is usually massive, so appending at the back will cost us a lot, we'll have to hand serialise this
            WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean extraNonce1 _ -> liftIO $ do
                -- get generate unique client nonce
                nonce <- nextNonce

                -- change the current job
                atomicWriteIORef (c_job local) $ Job job (unpackIntLE . fromHex $ extraNonce1, T.length extraNonce1 `quot` 2) (nonce, en2Size)

                -- set difficulty
                diff <- readIORef $ c_difficulty local
                writeResponse Null $ SetDifficulty $ diff * 65536

                -- set the work
                writeResponseRaw $ BL.toStrict $ TL.encodeUtf8 $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ "{\"id\":null,\"error\":null,\"method\":\"mining.notify\",\"params\":["
                    , "\"", job, "\","
                    , "\"", prev, "\",\""
                    , cb1
                    , extraNonce1
                    , packEn2 nonce
                    , "\",\"", cb2, "\","
                    , T.decodeUtf8 (BL.toStrict $ encode merkle), ","
                    , "\"", bv, "\","
                    , "\"", nbit, "\","
                    , "\"", ntime, "\","
                    , if clean then "true" else "false"
                    , "]}"
                    ]

            -- cap vardiff at upstream difficulty
            SetDifficulty diff -> liftIO $ atomicModifyIORef (c_difficulty local) $ max (diff / 65536) &&& const ()
            _ -> return ()

    -- wait for mining.authorization call
    user <- process handle $ \case
        Just (Request rid (Authorize user _)) -> do
            -- check if the address they are using is a valid address
            let valid = validateAddress (_publickeyByte . _settings $ global) $ T.encodeUtf8 user

            if | banned -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [ Number (-1), String $ "Your IP address is banned for too many invalid share submissions, the ban expires in " <> (T.pack . show . _banExpiry . _settings $ global) <> " minutes" ]
               | valid  -> do
                     liftIO $ writeResponse rid $ General $ Right $ Bool True
                     finish user
               | otherwise -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [ Number (-2), String "Username is not a valid address" ]

        _ -> continue

    infoM "client" $ T.unpack $ "Client " <> user <> " connected"

    -- vardiff thread
    (linkChild (c_handler local) =<<) . async . forever $ do
        let retargetTime     = _vardiffRetargetTime . _settings $ global
            target           = _vardiffTarget       . _settings $ global
            targetAllowance  = _vardiffAllowance    . _settings $ global
            minDifficulty    = _vardiffMin          . _settings $ global

        -- wait till retarget
        threadDelay $ retargetTime * 10^(6 :: Integer)

        accepted    <- fromIntegral <$> (readIORef $ c_lastShares local)
        currentDiff <- readIORef $ c_difficulty local

        -- convert accepted shares, difficulty to hashrate
        let estimatedHash = ad2h (accepted            * (60 / fromIntegral retargetTime)) currentDiff
            currentHash   = ad2h (fromIntegral target * (60 / fromIntegral retargetTime)) currentDiff

        -- check if hashrate is in vardiff allowance
        unless (currentHash * (1 - targetAllowance) < estimatedHash && estimatedHash < currentHash * (1 + targetAllowance)) $ do
            upstreamDiff <- readIORef $ _upstreamDiff global
            -- cap difficulty to min and upstream
            let newDiff = min (max minDifficulty $ ah2d (fromIntegral target * (60 / fromIntegral retargetTime)) estimatedHash) upstreamDiff

            writeIORef (c_difficulty local) newDiff
            writeResponse Null $ SetDifficulty $ newDiff * 65536

        -- check the number of dead this client is submitting
        lastShares <- readIORef (c_lastShares local)
        lastSharesDead <- readIORef (c_lastSharesDead local)

        -- ban the client if 90% of submitted shares are dead
        when (lastShares > target && (fromIntegral lastSharesDead / fromIntegral lastShares :: Double) >= 0.9) $ do
            writeChan (_banChan global) $ c_host local
            infoM "client" $ "Banned " ++ c_host local ++ " for too many dead shares"
            throwIO $ KillClientException "Too many dead shares submitted"

        -- clear the share counters
        writeIORef (c_lastShares local) 0
        writeIORef (c_lastSharesDead local) 0

    -- process workers submissions (forever)
    process handle $ \case
        Just (Request rid sub@(Submit{})) -> liftIO $ do
            job  <- readIORef $ c_job local
            diff <- readIORef $ c_difficulty local
            work <- readIORef $ _currentWork global

            let submitDiff = targetToDifficulty $ getPOW sub work (j_nonce1 job) (j_nonce2 job) (_extraNonce3Size . _settings $ global) scrypt

            -- verify job and share difficulty
            let valid = s_job sub == j_jobID job && submitDiff >= diff
            if valid
                then do
                    -- check if it meets upstream difficulty
                    upstreamDiff <- readIORef $ _upstreamDiff global

                    -- submit share to upstream
                    when (submitDiff >= upstreamDiff) $ upstreamRequest $ sub { s_worker = (_username . _settings $ global), s_extraNonce2 = packEn2 (fst . j_nonce2 $ job) <> s_extraNonce2 sub }

                    -- write response
                    writeResponse rid $ General $ Right $ Bool True
                else do
                    -- stale or invalid
                    writeResponse rid $ General $ Left $ Array $ V.fromList [Number (-3), String "Invalid share"]

            -- log the share
            writeChan (_shareChan global) $ Share user submitDiff (_serverName . _settings $ global) valid

            -- record share for vardiff
            atomicModifyIORef' (c_lastShares local) $ (1+) &&& const ()
            unless valid $ atomicModifyIORef' (c_lastSharesDead local) $ (1+) &&& const ()

        _ -> continue

finaliseClient :: ClientState -> IO ()
finaliseClient = finaliseHandler . c_handler

initaliseServer :: Handle -> IO ServerState
initaliseServer handle = ServerState <$> initaliseHandler handle <*> newChan

handleServer :: GlobalState -> ServerState -> IO ()
handleServer global local = do
    let
        handle :: Handle
        handle = _handle . s_handler $ local

        writeRequest :: Request -> IO ()
        writeRequest = writeChan (s_writerChan local) . BL.toStrict . encode

    -- thread to sequence writes
    (linkChild (s_handler local) =<<) . async . forever $ do
        line <- readChan (s_writerChan local)
        B8.hPutStrLn handle line

    -- subscribe to mining
    infoM "server" "Sending mining subscription"
    writeRequest $ Request (Number 1) Subscribe

    -- wait for subscription response
    (extraNonce1, originalEn2Size) <- process handle $ \case
        Just (Response (Number 1) (Initalise en1 oen2s)) -> finish (en1, oen2s)
        _ -> continue

    infoM "server" "Received subscription response"
    -- verify nonce configuration
    when (originalEn2Size /= (_extraNonce2Size . _settings $ global) + (_extraNonce3Size . _settings $ global)) $ error $ "Invalid nonce sizes specified, must add up to " ++ show originalEn2Size

    -- authorize
    infoM "server" "Sending authorization"
    writeRequest $ Request (Number 2) $ Authorize (_username . _settings $ global) (_password . _settings $ global)

    -- wait for authorization response
    process handle $ \case
        Just (Response (Number 2) (General (Right _))) -> finish ()
        Just (Response (Number 2) (General (Left _)))  -> error "Upstream authorisation failed"
        _ -> continue

    infoM "server" "Upstream authorized"

    -- thread to listen for server notifications
    (linkChild (s_handler local) =<<) . async $ do
        process handle $ liftIO . \case
            Just (Response _ wn@(WorkNotify{})) -> do
                return ()
                case fromWorkNotify wn of
                    Just work -> do
                        writeIORef (_currentWork global) work
                        writeChan (_notifyChan global) $ wn { wn_extraNonce1 = extraNonce1, wn_originalEn2Size = originalEn2Size }
                    Nothing   -> errorM "server" "Invalid upstream work received"
            Just (Response _ (SetDifficulty diff)) -> atomicWriteIORef (_upstreamDiff global) (diff / 65536)
            Just (Response (Number _) (General (Right _))) -> debugM "share" $ "Upstream share accepted"
            Just (Response (Number _) (General (Left  _))) -> debugM "share" $ "Upstream share rejected"
            _ -> return ()

    -- thread to listen to client requests (forever)
    forever $ readChan (_upstreamChan global) >>= writeRequest

finaliseServer :: ServerState -> IO ()
finaliseServer = finaliseHandler . s_handler

-- | Handle database queries
handleDB :: GlobalState -> R.Connection -> IO ()
handleDB global conn = do
    -- test connection first
    _ <- R.runRedis conn R.ping

    let channel = T.encodeUtf8 $ _redisChanName . _settings $ global

    -- handle share logging
    (link =<<) $ async $ forever $ readChan (_shareChan global) >>= \share -> do
        result <- R.runRedis conn $ R.publish channel $ BL.toStrict $ encode share
        case result of
            Right _ -> return ()
            Left  _ -> errorM "db" $ "Error while publishing share (" ++ show share ++ "): " ++ B8.unpack xs

    -- checking IPs
    (link =<<) $ async $ forever $ readChan (_checkChan global) >>= \(host, callback) -> do
        result <- R.runRedis conn $ R.exists $ B8.pack host
        case result of
            Right val -> callback val
            _         -> callback False

    -- banning IPs
    forever $ readChan (_banChan global) >>= \host -> do
        _ <- R.runRedis conn $ R.setex (B8.pack host) (60 * (fromIntegral . _banExpiry . _settings $ global)) ""
        return ()
