-----------------------------------------------------------------------------
--
-- Module      :  Base
-- Copyright   :
-- License     :  GPL (Just (Version {versionBranch = [3], versionTags = []}))
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}

-- show
module BaseRow  where
-- /show

import           Control.Applicative
import           Control.Monad.State
import           Data.Dynamic
import qualified Data.Map               as M
import           Data.Monoid
import           Debug.Trace
import           System.IO.Unsafe
import           Unsafe.Coerce

--import Data.IORef
import           Control.Concurrent
import           Control.Concurrent.STM
import           Data.List
import           Data.Maybe
import           GHC.Conc
import           System.Mem.StableName

(!>) =    flip trace
infixr 0 !>

data Transient m x= Transient  {runTrans :: m (Maybe x)}
type SData= ()

type EventId= Int



data EventF  = forall a b . EventF{xcomp      :: TransientIO a
                                  ,fcomp      :: a -> TransientIO b
                                  ,mfData     :: M.Map TypeRep SData
                                  ,mfSequence :: Int
                                  ,row        :: P RowElem
                                  ,replay     :: Bool
                                  ,newRow     :: Bool
                                  }

type P= MVar

(=:) :: P a  -> a -> IO()
(=:) n v= modifyMVar_ n $ const $ return v

type Buffer= Maybe ()
type NodeTuple= (EventId, ThreadId, Buffer)

type Children=   (P [P RowElem])

data RowElem=   Node NodeTuple  Children

instance Show RowElem where
     show (Node (e,_,_) ch)= show e ++ "->" ++ show ch

-- type Row = [P RowElem]

instance Eq NodeTuple where
     (i,_,_) ==  (i',_,_)= i == i'


instance Show x => Show (MVar x) where
  show  x = show (unsafePerformIO $ readMVar x)

eventf0= EventF  empty (const  empty) M.empty 0
          rootRef False False


topNode= (-1 :: Int,unsafePerformIO $ myThreadId,Nothing)

{-#NOINLINE rootRef#-}
rootRef :: MVar RowElem
rootRef=  unsafePerformIO $ newMVar $ Node topNode $ unsafePerformIO $ newMVar []

instance MonadState EventF  TransientIO where
  get=  Transient $ get >>= return . Just
  put x= Transient $ put x >> return (Just ())

type StateIO= StateT EventF  IO

type TransientIO= Transient StateIO

--runTrans ::  TransientIO x -> StateT EventF  IO (Maybe x)
--runTrans (Transient mx) = mx

runTransient :: TransientIO x -> IO (Maybe x, EventF)
runTransient t= runStateT (runTrans t) eventf0


setEventCont ::   TransientIO a -> (a -> TransientIO b) -> StateIO EventF
setEventCont x f  = do
   st@(EventF   _ fs d _  ro r nr)  <- get
   n <- if replay st then return $ mfSequence st
     else  liftIO $ readMVar refSequence

   put $ EventF   x ( \x -> f x >>= unsafeCoerce fs) d n  ro r nr !> ("stored " ++ show n)
   return st


resetEventCont (EventF x fs _ _  _ _ _)=do
   st@(EventF   _ _ d  n  ro r nr)  <- get
   put $ EventF  x fs d n  ro r nr


getCont ::(MonadState EventF  m) => m EventF
getCont = get

runCont :: EventF -> StateIO ()
runCont (EventF  x fs _ _  _ _ _)= do runIt  x (unsafeCoerce fs); return ()
   where
   runIt  x fs= runTrans $ do
         st <- get
         r <- x
         put st
         fs r


runClosure :: EventF -> StateIO (Maybe a)
runClosure (EventF x _ _ _ _ _ _) =  unsafeCoerce $ runTrans x

runContinuation ::  EventF -> a -> StateIO (Maybe b)
runContinuation (EventF _ fs _ _ _ _ _) x= runTrans $  (unsafeCoerce fs) x

instance   Functor TransientIO where
  fmap f x=   Transient $ fmap (fmap f) $ runTrans x --


instance Applicative TransientIO where
  pure a  = Transient  .  return $ Just a
  Transient f <*> Transient g= Transient $ do
       k <- f
       x <- g
       return $  k <*> x

instance  Alternative TransientIO where
  empty= Transient $ return  Nothing
  Transient f <|> Transient g= Transient $ do
       k <- f
       x <- g
       return $  k <|> x


-- | a sinonym of empty that can be used in a monadic expression. it stop the
-- computation
stop :: TransientIO a
stop= Control.Applicative.empty

instance Monoid a => Monoid (TransientIO a) where
  mappend x y = mappend <$> x <*> y
  mempty= return mempty

instance Monad TransientIO where
      return x = Transient $ return $ Just x
      x >>= f  = Transient $ do
        cont <- setEventCont x  f
        mk <- runTrans x
        resetEventCont cont
        case mk of
           Just k  -> runTrans $ f k

           Nothing -> return Nothing


addChild  r e= liftIO $ do
              ch <- newMVar []
              n <- newMVar $ Node e $ ch
              Node e' ch <- readMVar r
              modifyMVar_ ch (\h -> return (n:h))
              return n


instance MonadTrans (Transient ) where
  lift mx = Transient $ mx >>= return . Just

instance MonadIO TransientIO where
  liftIO = lift . liftIO --     let x= liftIO io in x `seq` lift x



-- | Get the session data of the desired type if there is any.
getSessionData ::  (MonadState EventF m,Typeable a) =>  m (Maybe a)
getSessionData =  resp where
 resp= gets mfData >>= \list  ->
    case M.lookup ( typeOf $ typeResp resp ) list of
      Just x  -> return . Just $ unsafeCoerce x
      Nothing -> return $ Nothing
 typeResp :: m (Maybe x) -> x
 typeResp= undefined

-- | getSessionData specialized for the View monad. if Nothing, the
-- monadic computation does not continue. getSData is a widget that does
-- not validate when there is no data of that type in the session.
getSData :: MonadState EventF m => Typeable a =>Transient m  a
getSData= Transient getSessionData


-- | setSessionData ::  (StateType m ~ MFlowState, Typeable a) => a -> m ()
setSessionData  x=
  modify $ \st -> st{mfData= M.insert  (typeOf x ) (unsafeCoerce x) (mfData st)}

-- | a shorter name for setSessionData
setSData ::  ( MonadState EventF m,Typeable a) => a -> m ()
setSData= setSessionData

delSessionData x=
  modify $ \st -> st{mfData= M.delete (typeOf x ) (mfData st)}

delSData :: ( MonadState EventF m,Typeable a) => a -> m ()
delSData= delSessionData

withSData ::  ( MonadState EventF m,Typeable a) => (Maybe a -> a) -> m ()
withSData f= modify $ \st -> st{mfData=
    let dat = mfData st
        mx= M.lookup typeofx dat
        mx'= case mx of Nothing -> Nothing; Just x -> unsafeCoerce x
        fx=  f mx'
        typeofx= typeOf $ typeoff f
    in  M.insert typeofx  (unsafeCoerce fx) dat}
    where
    typeoff :: (Maybe a -> a) -> a
    typeoff = undefined
----

genNewId :: MonadIO m => MonadState EventF m =>  m Int
genNewId=  do
      st <- get
      case replay st of
        True -> do
          let n= mfSequence st
          put $ st{mfSequence= n+1}
          return n
        False -> liftIO $
          modifyMVar refSequence $ \n -> return (n+1,n)

refSequence :: MVar Int
refSequence= unsafePerformIO $ newMVar 0



data Loop= Once | Loop | Multithread deriving Eq

waitEvents ::  IO b -> TransientIO b
waitEvents= parallel Loop


async  :: IO b -> TransientIO b
async = parallel Once

spawn= parallel Multithread

parallel  ::  Loop ->  IO b -> TransientIO b
parallel hasloop receive =  Transient $ do
      cont <- getCont
      id <- genNewId
      liftIO $ forkCont id hasloop receive cont

forkCont::  EventId -> Loop -> IO a -> EventF -> IO (Maybe a)
forkCont id hasloop receive cont= do
      let currentRow= row cont
      return() !> ("idToLook="++ show id++ " in: "++ show currentRow)
      found <- lookupThread id currentRow
      case found of
        Nothing ->do
                 return () !> "NOT FOUND"
                 forkCont' id cont hasloop receive
                 return Nothing

        Just (id',th', mrec) ->  return $ if isJust mrec then Just $ unsafeCoerce $ fromJust mrec else Nothing !> "FOUND"

        where
        forkCont' id  cont' hasloop receive= liftIO $ forkIO $ do
                     th <- myThreadId
                     ref <- addChild (row cont') (id,th,Nothing)
                     let cont = case newRow cont' of
                                 True -> cont'  {row=ref,newRow= False}
                                 False -> cont'
                     loop hasloop  receive $ \r -> do
                       
                       modifyMVar_  ref $ \(Node(i,th,_) ch) -> return
                                       $ Node(i,th,Just $ unsafeCoerce r) ch !> "LOOP"
                       (flip runStateT) cont $ do
                           cont@(EventF  x fs _  _ _ _ _) <- get

                           put cont{replay= True}

                           mr <- runClosure cont
                           case mr  of
                             Nothing ->return Nothing
                             Just r ->do
                               row1 <- gets row   !> "JUST"
                               liftIO $ delEvents  row1              !> ("delEvents: "++ show row1)
                               id <- liftIO $ readMVar refSequence
                               modify $ \cont -> cont{replay= False,mfSequence=id,newRow=True } !> ("SEQ=" ++ show(mfSequence cont))
                               runContinuation cont r
                       return ()


        assignThread ref= do
              th <- myThreadId
              modifyMVar_  ref $ \(Node(i,_,buf) ch) -> return $ Node (i,th,buf) ch
              
        loop Once rec x  = rec >>= x
        loop Loop rec f = do
            r <- rec
            f r
            loop Loop rec f

        loop Multithread rec f = do
            r <- rec
            forkIO $ f r
            loop Multithread rec f

        lookupThread id row= do
            Node _ r <- readMVar row
            chs <- readMVar r
            f chs
            where
            f []= return Nothing
            f (ch:chs)= do
                Node (nod@(id',_,_)) _ <- readMVar ch
                if id == id' then return $ Just nod else f chs
        
        delEvents :: P RowElem  -> IO()
        delEvents ref = do
            Node _ mch <-  readMVar ref
            maybeDel mch
            modifyMVar_ mch $ const $ return []
            

        maybeDel p=  do
                  es <- readMVar p
                  mapM_ delEvents' es  !> ("toDelete="++ show es)

        delEvents' :: P RowElem  -> IO()
        delEvents' ref = do
            Node (_,th,_) mch <- readMVar ref
            killThread th
            maybeDel mch

type EventSetter eventdata response= (eventdata ->  IO response) -> IO ()
type ToReturn  response=  IO response
react
  :: Typeable eventdata
  => EventSetter eventdata response
  -> ToReturn  response
  -> TransientIO eventdata

react setHandler iob= Transient $ do
        cont    <- getCont
        mEvData <- getSessionData
        case mEvData of
          Nothing -> do
            liftIO $ setHandler $ \dat ->do
--              let cont'= cont{mfData = M.insert (typeOf dat)(unsafeCoerce dat) (mfData cont)}
              runStateT (setSData dat >> runCont cont) cont
              iob
            return Nothing
          Just dat -> delSessionData dat >> return (Just  dat)

--hash f= liftIO $ do
--          st <- makeStableName $! f `seq` f
--          return $hashStableName st

--uhash= unsafePerformIO .hash

getLineRef= unsafePerformIO $ newTVarIO Nothing


option1 x  message=  inputLoop `seq` (waitEvents  $ do
     liftIO $ putStrLn $ message++"("++show x++")"
     atomically $ do
       mr <- readTVar getLineRef
       th <- unsafeIOToSTM myThreadId
       case mr of
         Nothing -> retry
         Just r ->
            case reads1 r !> ("received " ++  show r ++  show th) of
            (s,_):_ -> if  s == x  !> ("waiting" ++ show x)
                     then do
                       writeTVar  getLineRef Nothing !>"match"
                       return s

                     else retry
            _ -> retry)
     where
     reads1 s=x where
      x= if typeOf(typeOfr x) == typeOf "" then unsafeCoerce[(s,"")] else readsPrec 0 s
      typeOfr :: [(a,String)] ->  a
      typeOfr  = undefined

option ret message= do
    liftIO $ putStrLn $"Enter "++show ret++"\tto: " ++ message
    waitEvents  $ getLine' (==ret)
    liftIO $do putStrLn $ show ret ++ " chosen"
    return ret

getLine' cond=   inputLoop `seq` do
     atomically $ do
       mr <- readTVar getLineRef
       th <- unsafeIOToSTM myThreadId
       case mr of
         Nothing -> retry
         Just r ->
            case reads1 r !> ("received " ++  show r ++ show th) of
            (s,_):_ -> if cond s  !> show (cond s)
                     then do
                       writeTVar  getLineRef Nothing !>"match"
                       return s

                     else retry
            _ -> retry
     where
     reads1 s=x where
      x= if typeOf(typeOfr x) == typeOf "" then unsafeCoerce[(s,"")] else readsPrec 0 s
      typeOfr :: [(a,String)] ->  a
      typeOfr  = undefined

inputLoop=  do
    print "Press end to exit"
    inputLoop'
    where
        inputLoop'= do
           r<- getLine                      !> "started inputLoop"
           if r=="end" then putMVar rexit () else do
              atomically . writeTVar  getLineRef $ Just r
              inputLoop'


rexit= unsafePerformIO newEmptyMVar

stay=  takeMVar rexit

onNothing iox iox'= do
       mx <- iox
       case mx of
           Just x -> return x
           Nothing -> iox'