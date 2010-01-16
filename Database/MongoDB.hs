module Database.MongoDB
    (
     connect, connectOnPort,
     delete, insert, insertMany, query, remove, update,
     Collection, FieldSelector, NumToSkip, NumToReturn, RequestID, Selector,
     Opcode(..),
     QueryOpt(..),
     UpdateFlag(..),
    )
where
import Control.Exception (assert)
import Control.Monad
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import Data.ByteString.Char8
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.UTF8 as L8
import Data.Int
import Data.IORef
import qualified Data.List as List
import Database.MongoDB.BSON
import Database.MongoDB.Util
import qualified Network
import Network.Socket hiding (connect, send, sendTo, recv, recvFrom)
import Prelude hiding (getContents)
import System.IO
import System.Random

data Connection = Connection { cHandle :: Handle, cRand :: IORef [Int] }

connect :: HostName -> IO Connection
connect = flip connectOnPort $ Network.PortNumber 27017

connectOnPort :: HostName -> Network.PortID -> IO Connection
connectOnPort host port = do
  h <- Network.connectTo host port
  hSetBuffering h NoBuffering
  r <- newStdGen
  let ns = randomRs (fromIntegral (minBound :: Int32),
                     fromIntegral (maxBound :: Int32)) r
  nsRef <- newIORef ns
  return $ Connection { cHandle = h, cRand = nsRef }

data Opcode
    = OP_REPLY          -- 1     Reply to a client request. responseTo is set
    | OP_MSG            -- 1000	 generic msg command followed by a string
    | OP_UPDATE         -- 2001  update document
    | OP_INSERT	        -- 2002	 insert new document
    | OP_GET_BY_OID	-- 2003	 is this used?
    | OP_QUERY	        -- 2004	 query a collection
    | OP_GET_MORE	-- 2005	 Get more data from a query. See Cursors
    | OP_DELETE	        -- 2006	 Delete documents
    | OP_KILL_CURSORS	-- 2007	 Tell database client is done with a cursor
    deriving (Show, Eq)

fromOpcode OP_REPLY        =    1
fromOpcode OP_MSG          = 1000
fromOpcode OP_UPDATE       = 2001
fromOpcode OP_INSERT       = 2002
fromOpcode OP_GET_BY_OID   = 2003
fromOpcode OP_QUERY        = 2004
fromOpcode OP_GET_MORE     = 2005
fromOpcode OP_DELETE       = 2006
fromOpcode OP_KILL_CURSORS = 2007

toOpcode    1 = OP_REPLY
toOpcode 1000 = OP_MSG
toOpcode 2001 = OP_UPDATE
toOpcode 2002 = OP_INSERT
toOpcode 2003 = OP_GET_BY_OID
toOpcode 2004 = OP_QUERY
toOpcode 2005 = OP_GET_MORE
toOpcode 2006 = OP_DELETE
toOpcode 2007 = OP_KILL_CURSORS

type Collection = String
type Selector = BSONObject
type FieldSelector = BSONObject
type RequestID = Int32
type NumToSkip = Int32
type NumToReturn = Int32

data QueryOpt = QO_TailableCursor
               | QO_SlaveOK
               | QO_OpLogReplay
               | QO_NoCursorTimeout
               deriving (Show)

fromQueryOpts opts = List.foldl (.|.) 0 $ fmap toVal opts
    where toVal QO_TailableCursor = 2
          toVal QO_SlaveOK = 4
          toVal QO_OpLogReplay = 8
          toVal QO_NoCursorTimeout = 16

data UpdateFlag = UF_Upsert
                | UF_Multiupdate
                deriving (Show, Enum)

fromUpdateFlags flags = List.foldl (.|.) 0 $
                        flip fmap flags $ (1 `shiftL`) . fromEnum

delete :: Connection -> Collection -> Selector -> IO RequestID
delete c col sel = do
  let body = runPut $ do
                     putI32 0
                     putCol col
                     putI32 0
                     put sel
  (reqID, msg) <- packMsg c OP_DELETE body
  L.hPut (cHandle c) msg
  return reqID

remove = delete

insert :: Connection -> Collection -> BSONObject -> IO RequestID
insert c col doc = do
  let body = runPut $ do
                     putI32 0
                     putCol col
                     put doc
  (reqID, msg) <- packMsg c OP_INSERT body
  L.hPut (cHandle c) msg
  return reqID

insertMany :: Connection -> Collection -> [BSONObject] -> IO RequestID
insertMany c col docs = do
  let body = runPut $ do
               putI32 0
               putCol col
               forM_ docs put
  (reqID, msg) <- packMsg c OP_INSERT body
  L.hPut (cHandle c) msg
  return reqID

query :: Connection -> Collection -> [QueryOpt] -> NumToSkip -> NumToReturn ->
         Selector -> Maybe FieldSelector -> IO [BSONObject]
query c col opts skip ret sel fsel = do
  let body = runPut $ do
               putI32 $ fromQueryOpts opts
               putCol col
               putI32 skip
               putI32 ret
               put sel
               case fsel of
                    Nothing -> putNothing
                    Just fsel -> put fsel
  (reqID, msg) <- packMsg c OP_QUERY body
  L.hPut (cHandle c) msg
  getReply c reqID

update :: Connection -> Collection ->
          [UpdateFlag] -> Selector -> BSONObject -> IO RequestID
update c col flags sel obj = do
  let body = runPut $ do
               putI32 0
               putCol col
               putI32 $ fromUpdateFlags flags
               put sel
               put obj
  (reqID, msg) <- packMsg c OP_UPDATE body
  L.hPut (cHandle c) msg
  return reqID


data Hdr = Hdr {
      hMsgLen :: Int32,
      hReqID :: Int32,
      hRespTo :: Int32,
      hOp :: Opcode
    } deriving (Show)

data Reply = Reply {
      rRespFlags :: Int32,
      rCursorID :: Int64,
      rStartFrom :: Int32,
      rNumReturned :: Int32
    } deriving (Show)

getReply :: Connection -> RequestID -> IO [BSONObject]
getReply c reqID = do
  let h = cHandle c
  hdrBytes <- L.hGet h 16
  let hdr = flip runGet hdrBytes $ do
                     msgLen <- getI32
                     reqID <- getI32
                     respTo <- getI32
                     op <- getI32
                     return $ Hdr msgLen reqID respTo $ toOpcode op
  assert (OP_REPLY == hOp hdr) $ return ()
  assert (hRespTo hdr == reqID) $ return ()
  replyBytes <- L.hGet h 20
  let reply = flip runGet replyBytes $ do
                     respFlags <- getI32
                     cursorID <- getI64
                     startFrom <- getI32
                     numReturned <- getI32
                     return $ (Reply respFlags cursorID startFrom numReturned)
  assert (rRespFlags reply == 0) $ return ()
  docBytes <- L.hGet h $ fromIntegral $ hMsgLen hdr - 16 - 20
  return $ flip runGet docBytes $ do
                     forM [1 .. rNumReturned reply] $ \_ -> get

putCol col = putByteString (pack col) >> putNull

packMsg :: Connection -> Opcode -> L.ByteString -> IO (RequestID, L.ByteString)
packMsg c op body = do
  reqID <- randNum c
  let msg = runPut $ do
                      putI32 $ fromIntegral $ L.length body + 16
                      putI32 reqID
                      putI32 0
                      putI32 $ fromOpcode op
                      putLazyByteString body
  return (reqID, msg)

randNum :: Connection -> IO Int32
randNum Connection { cRand = nsRef } = atomicModifyIORef nsRef $ \ns ->
                                       (List.tail ns,
                                        fromIntegral $ List.head ns)
