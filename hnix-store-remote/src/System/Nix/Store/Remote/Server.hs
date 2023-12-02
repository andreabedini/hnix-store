{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
module System.Nix.Store.Remote.Server where

import Control.Concurrent.Classy.Async
import Control.Monad (join, void, when)
import Control.Monad.Conc.Class (MonadConc)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.Reader (MonadReader, asks)
import Control.Monad.Trans (lift)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import Data.Some (Some(Some))
import Data.Text (Text)
import Data.Void (Void, absurd)
import Data.Word (Word32)
import qualified Data.Text
import qualified Data.Text.IO
import Network.Socket (Socket, accept, close, listen, maxListenQueue)
import System.Nix.StorePath (StoreDir)
import System.Nix.Store.Remote.Serializer as RB
import System.Nix.Store.Remote.Socket
import System.Nix.Store.Remote.Types.StoreRequest as R
import System.Nix.Store.Remote.Types.StoreConfig (HasStoreSocket(..), StoreConfig(..), PreStoreConfig(..), preStoreConfigToStoreConfig)
import System.Nix.Store.Remote.Types.ProtoVersion (HasProtoVersion(..), ProtoVersion(..))
import System.Nix.Store.Remote.Types.Logger (BasicError(..), ErrorInfo, Logger(..))

import System.Nix.Store.Remote.MonadStore (WorkerError(..), WorkerException(..), RemoteStoreError(..), RemoteStoreT, runRemoteStoreT, mapStoreConfig)
import System.Nix.Store.Remote.Types.Handshake (Handshake(..))
import System.Nix.Store.Remote.Types.ProtoVersion (ourProtoVersion)
import System.Nix.Store.Remote.Types.WorkerMagic (WorkerMagic(..))

type WorkerHelper m = forall a. StoreRequest a -> m a

-- | Run an emulated nix daemon on given socket address.
-- The deamon will close when the continuation returns.
runDaemonSocket
  :: forall m a
  . ( MonadIO m
    , MonadConc m
    , MonadError RemoteStoreError m
    , MonadReader StoreConfig m
    )
  => StoreDir
  -> WorkerHelper m
  -> Socket
  -> m a
  -> m a
runDaemonSocket sd workerHelper lsock k = do
  liftIO $ listen lsock maxListenQueue

  liftIO $ Data.Text.IO.putStrLn "listening"

  let listener :: m Void
      listener = do
        (sock, _) <- liftIO $ accept lsock
        liftIO $ Data.Text.IO.putStrLn "accepting"

        let preStoreConfig = PreStoreConfig
              { preStoreConfig_socket = sock
              , preStoreConfig_dir = sd
              }

        -- TODO: this, but without the space leak
        fmap fst $ concurrently listener $ processConnection workerHelper preStoreConfig

  either absurd id <$> race listener k

-- | "main loop" of the daemon for a single connection.
--
-- this function should take care to not throw errors from client connections.
processConnection
  :: ( MonadIO m
     , MonadError RemoteStoreError m
     , MonadReader StoreConfig m
     )
  => WorkerHelper m
  -> PreStoreConfig
  -> m ()
processConnection workerHelper preStoreConfig = do
  let handshake = Handshake
        { handshakeNixVersion = Just "nixVersion (hnix-store-remote)"
        , handshakeTrust = Nothing
        -- TODO: doesn't make sense for server
        , handshakeProtoVersion = ourProtoVersion
        -- TODO: doesn't make sense for server
        , handshakeRemoteProtoVersion = ourProtoVersion
        -- TODO: try this
        , handshakeLogs = mempty
        }

  ~() <- void $ runRemoteStoreT preStoreConfig $ do

    minimumCommonVersion <- greet handshake

    mapStoreConfig
      (preStoreConfigToStoreConfig minimumCommonVersion)
      $ do

        tunnelLogger <- liftIO $ newTunnelLogger
        -- Send startup error messages to the client.
        startWork tunnelLogger

        -- TODO: do we need auth at all?  probably?
        -- If we can't accept clientVersion, then throw an error *here* (not above).
        --authHook(*store);
        stopWork tunnelLogger

        -- Process client requests.
        let loop = do
              someReq <-
                sockGetS
                  $ mapErrorS
                      RemoteStoreError_SerializerGet
                      storeRequest

              lift $ performOp' workerHelper tunnelLogger someReq
              loop
        loop

  liftIO $ Data.Text.IO.putStrLn "daemon connection done"
  liftIO $ close $ preStoreConfig_socket preStoreConfig

  where
    -- Exchange the greeting.
    greet
      :: MonadIO m
      => Handshake
      -> RemoteStoreT PreStoreConfig m ProtoVersion
    greet Handshake{..} = do
      magic <-
        sockGetS
        $ mapErrorS
            RemoteStoreError_SerializerHandshake
            workerMagic

      liftIO $ print ("magic" :: Text, magic)
      when (magic /= WorkerMagic_One)
        $ throwError $ RemoteStoreError_WorkerException WorkerException_ProtocolMismatch

      sockPutS
        (mapErrorS
          RemoteStoreError_SerializerHandshake
          workerMagic
        )
        WorkerMagic_Two

      sockPutS protoVersion ourProtoVersion

      clientVersion <- sockGetS protoVersion

      let minimumCommonVersion = min clientVersion ourProtoVersion

      liftIO $ print ("Versions client, min" :: Text, clientVersion, minimumCommonVersion)

      when (clientVersion < ProtoVersion 1 10)
        $ throwError
        $ RemoteStoreError_WorkerException
            WorkerException_ClientVersionTooOld

      when (clientVersion >= ProtoVersion 1 14) $ do
        x :: Word32 <- sockGetS int
        when (x /= 0) $ do
          -- Obsolete CPU affinity.
          _ :: Word32 <- sockGetS int
          pure ()

      when (clientVersion >= ProtoVersion 1 11) $ do
        _ :: Word32 <- sockGetS int -- obsolete reserveSpace
        pure ()

      when (clientVersion >= ProtoVersion 1 33) $ do
        sockPutS
          (mapErrorS
             RemoteStoreError_SerializerPut
             text
          )
          -- TODO
          (maybe undefined id handshakeNixVersion)

      when (clientVersion >= ProtoVersion 1 35) $ do
        sockPutS
          (mapErrorS
             RemoteStoreError_SerializerHandshake
             trustedFlag
          )
          handshakeTrust

      pure minimumCommonVersion

simpleOp
  :: ( MonadIO m
     , HasStoreSocket r
     , HasProtoVersion r
     , MonadError RemoteStoreError m
     , MonadReader r m
     )
  => (StoreRequest () -> m ())
  -> TunnelLogger r
  -> m (StoreRequest ())
  -> m ()
simpleOp workerHelper tunnelLogger m = do
  req <- m
  bracketLogger tunnelLogger $ workerHelper req
  sockPutS
    (mapErrorS
       RemoteStoreError_SerializerPut
       bool
    )
    True

simpleOpRet
  :: ( MonadIO m
     , HasStoreSocket r
     , HasProtoVersion r
     , MonadError RemoteStoreError m
     , MonadReader r m
     )
  => (StoreRequest a -> m a)
  -> TunnelLogger r
  -> NixSerializer r SError a
  -> m (StoreRequest a)
  -> m ()
simpleOpRet workerHelper tunnelLogger s m = do
  req <- m
  resp <- bracketLogger tunnelLogger $ workerHelper req
  sockPutS
    (mapErrorS
       RemoteStoreError_SerializerPut
       s
    )
    resp

bracketLogger
  :: ( MonadIO m
     , HasStoreSocket r
     , HasProtoVersion r
     , MonadReader r m
     , MonadError RemoteStoreError m
     )
  => TunnelLogger r
  -> m a
  -> m a
bracketLogger tunnelLogger m = do
  startWork tunnelLogger
  a <- m
  stopWork tunnelLogger
  pure a

{-# WARNING unimplemented "not yet implemented" #-}
unimplemented :: WorkerException
unimplemented = WorkerException_Error $ WorkerError_NotYetImplemented

performOp'
  :: forall m
   . ( MonadIO m
     , MonadError RemoteStoreError m
     , MonadReader StoreConfig m
     )
  => WorkerHelper m
  -> TunnelLogger StoreConfig
  -> Some StoreRequest
  -> m ()
performOp' workerHelper tunnelLogger op = do
  let _simpleOp' = simpleOp workerHelper tunnelLogger
  let simpleOpRet'
        :: NixSerializer StoreConfig SError a
        -> m (StoreRequest a)
        -> m ()
      simpleOpRet' = simpleOpRet workerHelper tunnelLogger

  case op of
    Some (IsValidPath path) -> simpleOpRet' bool $ do
      pure $ R.IsValidPath path

    _ -> undefined

{--
    HasSubstitutes -> do
      p <- sockGetS storePath
      s <- bracketLogger tunnelLogger $
        lift . workerHelper $ R.QuerySubstitutablePaths $ HashSet.singleton p
      sockPutS bool $ not $ HashSet.null s

    QueryPathHash -> throwM unimplemented
    QueryReferences -> throwM unimplemented

    P.QueryReferrers -> simpleOpRet' (hashSet storePath) $
      sockGetS $ R.QueryReferrers <$> storePath

    P.AddToStore -> do
      sock <- asks hasStoreSocket
      req <- sockGetS $ do
        name <- storePathName
        _ignore <- bool
        recursive <- bool
        algo <- someHashAlgo
        let source :: forall m2. MonadIO m2 => NarSource m2
            source k = k =<< liftIO (recv sock 8)
        pure $ R.AddToStore name recursive algo source RepairMode_DontRepair
      p <- bracketLogger tunnelLogger $ lift $ workerHelper req
      sockPutS storePath p

    P.AddTextToStore -> do
      req <- sockGetS $ R.AddTextToStore
        <$> text
        <*> text
        <*> hashSet storePath
        <*> pure RepairMode_DontRepair -- repairing is not supported when building through the Nix daemon
      p <- bracketLogger tunnelLogger $ lift $ workerHelper req
      sockPutS storePath p

    P.BuildPaths -> simpleOp' $sockGetS $
      R.BuildPaths
        <$> set derivedPath
        <*> enum

    P.EnsurePath -> simpleOp' $ sockGetS $
      R.EnsurePath
        <$> storePath

    P.AddTempRoot -> simpleOp' $ sockGetS $
      R.AddTempRoot
        <$> storePath

    P.AddIndirectRoot -> simpleOp' $ sockGetS $
      R.AddIndirectRoot
        <$> storePath

    P.SyncWithGC -> simpleOp' $ pure R.SyncWithGC

    P.FindRoots -> simpleOpRet'
      (mapS byteString storePath)
      $ pure R.FindRoots

    Reserved_15__ -> throwM invalidOp
    P.ExportPath -> throwM unimplemented
    Reserved_17__ -> throwM invalidOp

    QueryDeriver -> do
      p <- sockGetS storePath
      m_info <- bracketLogger tunnelLogger $
        lift . workerHelper $ R.QueryPathInfo p
      sockPutS maybePath $ deriverPath =<< m_info

    SetOptions -> throwM unimplemented
    CollectGarbage -> throwM unimplemented
    QuerySubstitutablePathInfo -> throwM unimplemented

    P.QueryDerivationOutputs -> simpleOpRet' (hashSet storePath) $ sockGetS $
      R.QueryDerivationOutputs
        <$> storePath

    P.QueryAllValidPaths -> simpleOpRet' (hashSet storePath) $
      pure $ R.QueryAllValidPaths

    P.QueryFailedPaths -> throwM unimplemented
    P.ClearFailedPaths -> throwM unimplemented

-- TODO trust
-- TODO: maybe
--    P.QueryPathInfo -> simpleOpRet' (RB.maybe pathMetadata) $
--      sockGetS $ R.QueryPathInfo
--        <$> storePath

    P.ImportPaths -> throwM unimplemented

    P.QueryDerivationOutputNames -> simpleOpRet' (hashSet storePathName) $ sockGetS $
      R.QueryDerivationOutputNames
        <$> storePath

    P.QueryPathFromHashPart -> simpleOpRet' storePath $ sockGetS $
      R.QueryPathFromHashPart
        <$> storePathHashPart

    QuerySubstitutablePathInfos -> throwM unimplemented

    P.QueryValidPaths -> simpleOpRet' (hashSet storePath) $
      sockGetS $ R.QueryValidPaths
        <$> hashSet storePath
        <*> enum

    P.QuerySubstitutablePaths -> simpleOpRet' (hashSet storePath) $
      sockGetS $ R.QuerySubstitutablePaths
        <$> hashSet storePath

    P.QueryValidDerivers -> simpleOpRet' (hashSet storePath) $
      sockGetS $ R.QueryValidDerivers
        <$> storePath

    P.OptimiseStore -> simpleOp' $ pure R.OptimiseStore

    P.VerifyStore -> simpleOpRet' bool $ sockGetS $
      R.VerifyStore
        <$> enum
        <*> enum

    P.BuildDerivation -> simpleOpRet' buildResult $ sockGetS $
      R.BuildDerivation
        <$> storePath
        <*> derivation
        <*> enum
      <* int @Word32 -- TODO: why

    P.AddSignatures -> simpleOp' $ sockGetS $
      R.AddSignatures
        <$> storePath
        <*> list byteString

    --P.QueryMissing -> simpleOp' $
--}

---

data TunnelLogger r = TunnelLogger
  { _tunnelLogger_state :: IORef (TunnelLoggerState r)
  }

data TunnelLoggerState r = TunnelLoggerState
  { _tunnelLoggerState_canSendStderr :: Bool
  , _tunnelLoggerState_pendingMsgs :: [Logger]
  }

newTunnelLogger :: IO (TunnelLogger r)
newTunnelLogger = TunnelLogger <$> newIORef (TunnelLoggerState False [])

enqueueMsg
  :: ( MonadIO m
     , MonadReader r m
     , MonadError LoggerSError m
     , HasProtoVersion r
     , HasStoreSocket r
     )
  => TunnelLogger r
  -> Logger
  -> m ()
enqueueMsg x l = updateLogger x $ \st@(TunnelLoggerState c p) -> case c of
  True -> (st, sockPutS logger l)
  False -> (TunnelLoggerState c (l:p), pure ())

log
  :: ( MonadIO m
     , MonadReader r m
     , HasStoreSocket r
     , MonadError LoggerSError m
     , HasProtoVersion r
     )
  => TunnelLogger r
  -> Text
  -> m ()
log l s = enqueueMsg l (Logger_Next s)

startWork
  :: (MonadIO m, MonadReader r m, HasStoreSocket r

     , MonadError RemoteStoreError m
     , HasProtoVersion r
  )
  => TunnelLogger r
  -> m ()
startWork x = updateLogger x $ \(TunnelLoggerState _ p) -> (,)
  (TunnelLoggerState True []) $
  (traverse_ (sockPutS logger') $ reverse p)
  where logger' = mapErrorS RemoteStoreError_SerializerLogger logger

stopWork
  :: (MonadIO m, MonadReader r m, HasStoreSocket r

     , MonadError RemoteStoreError m
     , HasProtoVersion r
  )
  => TunnelLogger r
  -> m ()
stopWork x = updateLogger x $ \_ -> (,)
  (TunnelLoggerState False [])
  (sockPutS (mapErrorS RemoteStoreError_SerializerLogger logger) Logger_Last)

-- | Stop sending logging and report an error.
--
-- Returns true if the the session was in a state that allowed the error to be
-- sent.
--
-- Unlike 'stopWork', this function may be called at any time to (try) to end a
-- session with an error.
stopWorkOnError
  :: (MonadIO m, MonadReader r m, HasStoreSocket r, HasProtoVersion r

    , MonadError RemoteStoreError m
  )
  => TunnelLogger r
  -> ErrorInfo
  -> m Bool
stopWorkOnError x ex = updateLogger x $ \st ->
  case _tunnelLoggerState_canSendStderr st of
    False -> (st, pure False)
    True -> (,) (TunnelLoggerState False []) $ do
      asks hasProtoVersion >>= \pv -> if protoVersion_minor pv >= 26
        then sockPutS logger' (Logger_Error (Right ex))
        else sockPutS logger' (Logger_Error (Left (BasicError 0 (Data.Text.pack $ show ex))))
      pure True
  where logger' = mapErrorS RemoteStoreError_SerializerLogger logger

updateLogger
  :: (MonadIO m, MonadReader r m, HasStoreSocket r)
  => TunnelLogger r
  -> (TunnelLoggerState r -> (TunnelLoggerState r, m a))
  -> m a
updateLogger x = join . liftIO . atomicModifyIORef (_tunnelLogger_state x)
