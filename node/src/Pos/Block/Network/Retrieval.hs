{-# LANGUAGE RankNTypes #-}

-- | Server which deals with blocks processing.

module Pos.Block.Network.Retrieval
       ( retrievalWorker
       ) where

import           Universum

import           Control.Concurrent.STM     (putTMVar, swapTMVar, tryReadTBQueue,
                                             tryReadTMVar, tryTakeTMVar)
import           Control.Lens               (to, _Wrapped)
import           Control.Monad.Except       (ExceptT, runExceptT, throwError)
import           Control.Monad.STM          (retry)
import           Data.List.NonEmpty         ((<|))
import qualified Data.List.NonEmpty         as NE
import qualified Data.Set                   as S
import           Ether.Internal             (HasLens (..))
import           Formatting                 (build, builder, int, sformat, stext, (%))
import           Mockable                   (delay, handleAll)
import           Serokell.Data.Memory.Units (unitBuilder)
import           Serokell.Util              (listJson, sec)
import           System.Wlog                (logDebug, logError, logInfo, logWarning)

import           Pos.Binary.Class           (biSize)
import           Pos.Binary.Communication   ()
import           Pos.Block.Core             (Block, BlockHeader, blockHeader)
import           Pos.Block.Logic            (ClassifyHeaderRes (..), classifyNewHeader)
import           Pos.Block.Network.Announce (announceBlockOuts)
import           Pos.Block.Network.Logic    (BlockNetLogicException (DialogUnexpected),
                                             MkHeadersRequestResult (..), handleBlocks,
                                             mkBlocksRequest, mkHeadersRequest,
                                             requestHeaders, triggerRecovery)
import           Pos.Block.Network.Types    (MsgBlock (..), MsgGetBlocks (..))
import           Pos.Block.RetrievalQueue   (BlockRetrievalTask (..))
import           Pos.Communication.Limits   (recvLimited)
import           Pos.Communication.Protocol (Conversation (..), ConversationActions (..),
                                             EnqueueMsg, MsgType (..), NodeId, OutSpecs,
                                             SendActions (..), WorkerSpec, convH,
                                             toOutSpecs, waitForConversations, worker)
import           Pos.Context                (BlockRetrievalQueueTag, ProgressHeaderTag,
                                             RecoveryHeaderTag)
import           Pos.Core                   (HasHeaderHash (..), HeaderHash, difficultyL,
                                             isMoreDifficult, prevBlockL)
import           Pos.Crypto                 (shortHashF)
import           Pos.Reporting              (reportOrLogE, reportOrLogW)
import           Pos.Shutdown               (runIfNotShutdown)
import           Pos.Ssc.Class              (SscWorkersClass)
import           Pos.Util                   (_neHead, _neLast)
import           Pos.Util.Chrono            (NE, NewestFirst (..), OldestFirst (..),
                                             _NewestFirst, _OldestFirst)
import           Pos.WorkMode.Class         (WorkMode)

retrievalWorker
    :: forall ssc ctx m.
       (SscWorkersClass ssc, WorkMode ssc ctx m)
    => (WorkerSpec m, OutSpecs)
retrievalWorker = worker outs retrievalWorkerImpl
  where
    outs = announceBlockOuts <>
           toOutSpecs [convH (Proxy :: Proxy MsgGetBlocks)
                             (Proxy :: Proxy (MsgBlock ssc))
                      ]

-- I really don't like join
{-# ANN retrievalWorkerImpl ("HLint: ignore Use join" :: Text) #-}

-- | Worker that queries blocks. It has two jobs:
--
-- * If there are headers in 'BlockRetrievalQueue', this worker retrieves
--   blocks according to that queue.
--
-- * If recovery is in progress, this worker keeps recovery going by asking
--   headers (and then switching to block retrieval on next loop iteration).
--
-- If both happen at the same time, 'BlockRetrievalQueue' takes precedence.
--
retrievalWorkerImpl
    :: forall ssc ctx m.
       (SscWorkersClass ssc, WorkMode ssc ctx m)
    => SendActions m -> m ()
retrievalWorkerImpl SendActions {..} =
    handleAll mainLoopE $ do
        logDebug "Starting retrievalWorker loop"
        mainLoop
  where
    mainLoop = runIfNotShutdown $ do
        queue        <- view (lensOf @BlockRetrievalQueueTag)
        recHeaderVar <- view (lensOf @RecoveryHeaderTag)
        logDebug "Waiting on the block queue or recovery header var"
        -- Reading the queue is a priority, because it sets the recovery
        -- variable in case the header is classified as alternative. So if the
        -- queue contains lots of headers after a long delay, we'll first
        -- iterate over them and set recovery variable to the latest one, and
        -- only then we'll do recovery.
        thingToDoNext <- atomically $ do
            mbQueuedHeadersChunk <- tryReadTBQueue queue
            mbRecHeader <- tryReadTMVar recHeaderVar
            case (mbQueuedHeadersChunk, mbRecHeader) of
                (Nothing, Nothing) -> retry
                -- Dispatch the task
                (Just (nodeId, task), _) ->
                    pure (handleBlockRetrieval nodeId task)
                -- No tasks & the recovery header is set => do the recovery
                (_, Just (nodeId, rHeader))  ->
                    pure (handleRecoveryWithHandler nodeId rHeader)
        thingToDoNext
        mainLoop
    mainLoopE e = do
        -- REPORT:ERROR 'reportOrLogE' in block retrieval worker.
        reportOrLogE "retrievalWorker mainLoopE: error caught " e
        delay (sec 1)
        mainLoop

    -----------------

    -- That's the first queue branch (task dispatching).
    handleBlockRetrieval nodeId BlockRetrievalTask{..} = do
        logDebug $ sformat
            ("Block retrieval queue task received, nodeId="%build%
             ", header="%build%", continues="%build)
            nodeId
            (headerHash brtHeader)
            brtContinues
        (if brtContinues then handleContinues else handleAlternative)
            nodeId
            brtHeader

    -- When we have a continuation of the chain, just try to get and apply it.
    handleContinues nodeId header = do
        logDebug $ "handleContinues: " <> pretty header
        processContHeader enqueueMsg nodeId header

    -- When we have an alternative header, we should check whether it's actually
    -- recovery mode (server side should send us headers as a proof) and then
    -- enter recovery mode.
    handleAlternative nodeId header = do
        logDebug $ "handleAlternative: " <> pretty header
        classifyNewHeader header >>= \case
            CHInvalid _ ->
                logError "handleAlternative: invalid header got into retrievalWorker queue"
            CHUseless _ ->
                logDebug $
                sformat ("handleAlternative: header "%build%" became useless, ignoring it")
                        header
            _ -> do
                logDebug "handleAlternative: considering header for recovery mode"
                -- CSL-1514
                updateRecoveryHeader nodeId header

    -----------------

    handleRecoveryWithHandler nodeId header =
        handleAll (handleRecoveryE nodeId header) $
        handleRecovery nodeId header

    -- We immediately drop recovery mode/header and request tips
    -- again.
    handleRecoveryE nodeId header e = do
        -- REPORT:ERROR 'reportOrLogW' in block retrieval worker/recovery.
        reportOrLogW (sformat
            ("handleRecoveryE: error handling nodeId="%build%", header="%build%": ")
            nodeId (headerHash header)) e
        dropUpdateHeader
        dropRecoveryHeaderAndRepeat enqueueMsg nodeId

    -- Recovery handling. We assume that header in the recovery variable is
    -- appropriate and just query headers/blocks.
    handleRecovery nodeId header = do
        logDebug "Block retrieval queue is empty and we're in recovery mode,\
                 \ so we will request more headers and blocks"
        mkHeadersRequest (headerHash header) >>= \case
            MhrrBlockAdopted ->
                -- How did we even got into recovery then?
                throwM $ DialogUnexpected "handleRecovery: got MhrrBlockAdopted"
            MhrrWithCheckpoints mgh -> do
                logDebug "handleRecovery: asking for headers"
                let cont (headers :: NewestFirst NE (BlockHeader ssc)) =
                        let oldestHeader = headers ^. _NewestFirst . _neLast
                            newestHeader = headers ^. _NewestFirst . _neHead
                        in handleCHsValid enqueueMsg nodeId
                                          oldestHeader (headerHash newestHeader)
                -- If it returns w/o exception then we're:
                --  * Either still in recovery mode
                --  * Or just exited it and recoverVar was taken.
                enqueueMsgSingle
                    enqueueMsg
                    (MsgRequestBlockHeaders $ Just $ S.singleton nodeId)
                    (Conversation $ requestHeaders cont mgh nodeId)

-- | Result of attempt to update recovery header.
data UpdateRecoveryResult ssc
    = RecoveryStarted NodeId (BlockHeader ssc)
      -- ^ Recovery header was absent, so we've set it.
    | RecoveryShifted NodeId (BlockHeader ssc) NodeId (BlockHeader ssc)
      -- ^ Header was present, but we've replaced it with another
      -- (more difficult) one.
    | RecoveryContinued NodeId (BlockHeader ssc)
      -- ^ Header is good, but is irrelevant, so recovery variable is
      -- unchanged.

-- | Be careful to run this in the same thread that ends recovery mode
-- (or synchronise those threads with an MVar), otherwise a race
-- condition can occur where we are caught in the recovery mode
-- indefinitely.
updateRecoveryHeader
    :: WorkMode ssc ctx m
    => NodeId
    -> BlockHeader ssc
    -> m ()
updateRecoveryHeader nodeId hdr = do
    recHeaderVar <- view (lensOf @RecoveryHeaderTag)
    logDebug "Updating recovery header..."
    updated <- atomically $ do
        mbRecHeader <- tryReadTMVar recHeaderVar
        case mbRecHeader of
            Nothing -> do
                putTMVar recHeaderVar (nodeId, hdr)
                return $ RecoveryStarted nodeId hdr
            Just (oldNodeId, oldHdr) -> do
                let needUpdate = hdr `isMoreDifficult` oldHdr
                if needUpdate
                    then swapTMVar recHeaderVar (nodeId, hdr) $>
                         RecoveryShifted oldNodeId oldHdr nodeId hdr
                    else return $ RecoveryContinued oldNodeId oldHdr
    logDebug $ case updated of
        RecoveryStarted rNodeId rHeader -> sformat
            ("Recovery started with nodeId="%build%" and tip="%build)
            rNodeId
            (headerHash rHeader)
        RecoveryShifted rNodeId' rHeader' rNodeId rHeader -> sformat
            ("Recovery shifted from nodeId="%build%" and tip="%build%
             " to nodeId="%build%" and tip="%build)
            rNodeId' (headerHash rHeader')
            rNodeId  (headerHash rHeader)
        RecoveryContinued rNodeId rHeader -> sformat
            ("Recovery continued with nodeId="%build%" and tip="%build)
            rNodeId
            (headerHash rHeader)

dropUpdateHeader :: WorkMode ssc ctx m => m ()
dropUpdateHeader = do
    progressHeaderVar <- view (lensOf @ProgressHeaderTag)
    void $ atomically $ tryTakeTMVar progressHeaderVar

-- | The returned 'Bool' signifies whether given peer was kicked and recovery
-- was stopped.
--
-- NB. The reason @nodeId@ is passed is that we want to avoid a race
-- condition. If you work with peer P and header H, after failure you want to
-- drop communication with P; however, if at the same time a new block
-- arrives and another thread replaces peer and header to (P2, H2), you want
-- to continue working with P2 and ignore the exception that happened with P.
-- So, @nodeId@ is used to check that the peer wasn't replaced mid-execution.
dropRecoveryHeader
    :: WorkMode ssc ctx m
    => NodeId
    -> m Bool
dropRecoveryHeader nodeId = do
    recHeaderVar <- view (lensOf @RecoveryHeaderTag)
    (kicked,realPeer) <- atomically $ do
        let processKick (peer,_) = do
                let p = peer == nodeId
                when p $ void $ tryTakeTMVar recHeaderVar
                pure (p, Just peer)
        maybe (pure (True,Nothing)) processKick =<< tryReadTMVar recHeaderVar
    when kicked $ logWarning $
        sformat ("Recovery mode communication dropped with peer "%build) nodeId
    unless kicked $
        logDebug $ "Recovery mode wasn't disabled: " <>
                   maybe "noth" show realPeer <> " vs " <> show nodeId
    pure kicked

-- | Drops the recovery header and, if it was successful, queries the tips.
dropRecoveryHeaderAndRepeat
    :: (SscWorkersClass ssc, WorkMode ssc ctx m)
    => EnqueueMsg m -> NodeId -> m ()
dropRecoveryHeaderAndRepeat enqueue nodeId = do
    kicked <- dropRecoveryHeader nodeId
    when kicked $ attemptRestartRecovery
  where
    attemptRestartRecovery = do
        logDebug "Attempting to restart recovery"
        delay $ sec 2
        handleAll handleRecoveryTriggerE $ triggerRecovery enqueue
        logDebug "Attempting to restart recovery over"
    handleRecoveryTriggerE =
        -- REPORT:ERROR 'reportOrLogE' somewhere in block retrieval.
        reportOrLogE $ "Exception happened while trying to trigger " <>
                       "recovery inside dropRecoveryHeaderAndRepeat: "

-- | Process header that was thought to be continuation. If it's not
-- now, it is discarded.
processContHeader
    :: (SscWorkersClass ssc, WorkMode ssc ctx m)
    => EnqueueMsg m
    -> NodeId
    -> BlockHeader ssc
    -> m ()
processContHeader enqueue nodeId header = do
    classificationRes <- classifyNewHeader header
    case classificationRes of
        CHContinues -> void $ handleCHsValid enqueue nodeId header (headerHash header)
        res -> logDebug $
            "processContHeader: expected header to " <>
             "be continuation, but it's " <> show res

-- Returns only if blocks were successfully downloaded and
-- processed. Throws exception if something goes wrong.
handleCHsValid
    :: forall ssc ctx m.
       (SscWorkersClass ssc, WorkMode ssc ctx m)
    => EnqueueMsg m
    -> NodeId
    -> BlockHeader ssc
    -> HeaderHash
    -> m ()
handleCHsValid enqueue nodeId lcaChild newestHash = do
    -- The conversation will attempt to retrieve the necessary blocks and apply
    -- them. Each one gives a 'Bool' where 'True' means that a recovery was
    -- completed (depends upon the state of the recovery-mode TMVar).
    enqueueMsgSingle enqueue (MsgRequestBlocks (S.singleton nodeId)) $ Conversation $
      \(conv :: ConversationActions MsgGetBlocks (MsgBlock ssc) m) -> do
        let lcaChildHash = headerHash lcaChild
        logDebug $ sformat ("Requesting blocks from "%shortHashF%" to "%shortHashF)
                           lcaChildHash
                           newestHash
        send conv $ mkBlocksRequest lcaChildHash newestHash
        logDebug "Requested blocks, waiting for the response"
        chainE <- runExceptT (retrieveBlocks conv lcaChild newestHash)
        recHeaderVar <- view (lensOf @RecoveryHeaderTag)
        case chainE of
            Left e -> do
                let msg = sformat ("Error retrieving blocks from "%shortHashF%
                                   " to "%shortHashF%" from peer "%
                                   build%": "%stext)
                                  lcaChildHash newestHash nodeId e
                logWarning msg
                throwM $ DialogUnexpected msg
            Right blocks -> do
                logDebug $ sformat
                    ("Retrieved "%int%" blocks of total size "%builder%": "%listJson)
                    (blocks ^. _OldestFirst . to NE.length)
                    (unitBuilder $ biSize blocks)
                    (map (headerHash . view blockHeader) blocks)
                handleBlocks nodeId blocks enqueue
                dropUpdateHeader
                -- If we've downloaded any block with bigger
                -- difficulty than ncrecoveryheader, we're
                -- gracefully exiting recovery mode.
                let isMoreDifficultThan b x = b ^. difficultyL >= x ^. difficultyL
                exitedRecovery <- atomically $ tryReadTMVar recHeaderVar >>= \case
                    -- We're not in recovery mode? That must be ok.
                    Nothing -> pure False
                    -- If we're in recovery mode we should exit it if
                    -- any block is more difficult than one in
                    -- recHeader.
                    Just (_, rHeader) ->
                        if any (`isMoreDifficultThan` rHeader) blocks
                        then isJust <$> tryTakeTMVar recHeaderVar
                        else pure False
                when exitedRecovery $
                    logInfo "Recovery mode exited gracefully on receiving block we needed"

retrieveBlocks
    :: (SscWorkersClass ssc, WorkMode ssc ctx m)
    => ConversationActions MsgGetBlocks (MsgBlock ssc) m
    -> BlockHeader ssc
    -> HeaderHash
    -> ExceptT Text m (OldestFirst NE (Block ssc))
retrieveBlocks conv lcaChild endH = do
    blocks <- retrieveBlocks' 0 conv (lcaChild ^. prevBlockL) endH
    let b0 = blocks ^. _OldestFirst . _neHead
    if headerHash b0 == headerHash lcaChild
       then pure blocks
       else throwError $ sformat
                ("First block of chain is "%build%
                 " instead of expected "%build)
                (b0 ^. blockHeader) lcaChild


retrieveBlocks'
    :: (SscWorkersClass ssc, WorkMode ssc ctx m)
    => Int        -- ^ Index of block we're requesting
    -> ConversationActions MsgGetBlocks (MsgBlock ssc) m
    -> HeaderHash -- ^ We're expecting a child of this block
    -> HeaderHash -- ^ Block at which to stop
    -> ExceptT Text m (OldestFirst NE (Block ssc))
retrieveBlocks' i conv prevH endH = lift (recvLimited conv) >>= \case
    Nothing ->
        throwError $ sformat ("Failed to receive block #"%int) i
    Just (MsgNoBlock t) ->
        throwError $ sformat ("Server failed to return block #"%int%": "%stext) i t
    Just (MsgBlock block) -> do
        let prevH' = block ^. prevBlockL
            curH = headerHash block
        when (prevH' /= prevH) $ do
            throwError $ sformat
                ("Received block #"%int%" with prev hash "%shortHashF%
                 " while "%shortHashF%" was expected: "%build)
                i prevH' prevH (block ^. blockHeader)
        progressHeaderVar <- view (lensOf @ProgressHeaderTag)
        atomically $ do void $ tryTakeTMVar progressHeaderVar
                        putTMVar progressHeaderVar $ block ^. blockHeader
        if curH == endH
        then pure $ one block
        else over _Wrapped (block <|) <$> retrieveBlocks' (i+1) conv curH endH

----------------------------------------------------------------------------
-- Networking
----------------------------------------------------------------------------

-- | Expects sending message to exactly one node. Receives result or
-- fails if no result was obtained (no nodes available, timeout, etc).
enqueueMsgSingle ::
       (MonadThrow m)
    => (t2 -> (t1 -> t -> NonEmpty x) -> m (Map NodeId (m b)))
    -> t2
    -> x
    -> m b
enqueueMsgSingle enqueue msg conv = do
    results <- enqueue msg (\_ _ -> one conv) >>=
               waitForConversations
    case toList results of
        [] ->      throwM $ DialogUnexpected $
            "enqueueMsgSingle: contacted no peers"
        (_:_:_) -> throwM $ DialogUnexpected $
            "enqueueMsgSingle: contacted more than one peers, probably internal error"
        [x] -> pure x
