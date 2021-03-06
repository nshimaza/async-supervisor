{-# OPTIONS_GHC -Wno-type-defaults #-}

module Control.Concurrent.SupervisorInternalSpec where

import           Data.Char                             (chr, ord)
import           Data.Default                          (def)
import           Data.Foldable                         (for_)
import           Data.List                             (sort)
import           Data.Maybe                            (fromJust, isNothing)
import           Data.Traversable                      (for)
import           UnliftIO                              (async, newEmptyMVar,
                                                        poll, putMVar, takeMVar,
                                                        wait, withAsync)
import           UnliftIO.Concurrent                   (threadDelay)

import           Test.Hspec
import           Test.Hspec.QuickCheck

import           Control.Concurrent.SupervisorInternal hiding (length)
import qualified Control.Concurrent.SupervisorInternal as Sv (length)

{-# ANN module "HLint: ignore Reduce duplication" #-}

data IntFin = Fin | IntVal Int

spec :: Spec
spec = do
    describe "Inbox receive" $ do
        prop "receives message in sent order" $ \xs -> do
            q <- newInbox def
            for_ (xs :: [Int]) $ send $ ActorQ q
            r <- for xs $ const $ receive q
            r `shouldBe` xs

        it "blocks until message available" $ do
            q <- newInbox def
            withAsync (receive q) $ \a -> do
                threadDelay 1000
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                send (ActorQ q) "Hello"
                r2 <- wait a
                r2 `shouldBe` "Hello"

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 100000)  $ prop "concurrent read and write to the same queue" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            withAsync (for_ xs (send actorQ . Just) *> send actorQ Nothing) $ \_ -> do
                let go ys = do
                        maybeInt <- receive q
                        case maybeInt of
                            Just y  -> go (y:ys)
                            Nothing -> pure $ reverse ys
                rs <- go []
                rs `shouldBe` (xs :: [Int])

    describe "Inbox tryReceive" $ do
        prop "receives message in sent order" $ \xs -> do
            q <- newInbox def
            for_ (xs :: [Int]) $ send $ ActorQ q
            r <- for xs $ const $ tryReceive q
            r `shouldBe` map Just xs

        it "returns Nothing if no message available" $ do
            q <- newInbox def :: IO (Inbox ())
            r <- tryReceive q
            r `shouldSatisfy` isNothing

    describe "Inbox receiveSelect" $ do
        it "allows selective receive" $ do
            q <- newInbox def
            let actorQ = ActorQ q

            for_ ['a'..'z'] $ send actorQ
            r1 <- receiveSelect (== 'a') q
            r1 `shouldBe` 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ send actorQ
            r3 <- receiveSelect (== 'h') q
            r3 `shouldBe` 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` ['a'..'g'] <> ['i'..'z']

            for_ ['a'..'z'] $ send actorQ
            r5 <- receiveSelect (== 'z') q
            r5 `shouldBe` 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ send actorQ
                r7 <- receiveSelect (== chr i) q
                ord r7 `shouldBe` i
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` ['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z']

        it "returns the first element satisfying supplied predicate" $ do
            q <- newInbox def
            for_ "abcdefabcdef" $ send $ ActorQ q
            r1 <- receiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "blocks until interesting message arrived" $ do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ ['a'..'y'] $ send actorQ
            withAsync (receiveSelect (== 'z') q) $ \a -> do
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                send actorQ 'z'
                r2 <- wait a
                r2 `shouldBe` 'z'

        prop "keeps entire content if predicate was never satisfied" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ (xs :: [Int]) $ send actorQ . Just
            for_ [1..2] $ \_ -> send actorQ Nothing
            let go ys = do
                    maybeInt <- receiveSelect isNothing q
                    case maybeInt of
                        Just y  -> go (y:ys)
                        Nothing -> pure $ reverse ys
            rs <- go []
            rs `shouldBe` []
            remains <- for xs $ const $ fromJust <$> receive q
            remains `shouldBe` xs

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 10000) $ prop "selectively reads massive number of messages concurrently" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            let evens = filter even xs :: [Int]
            withAsync (for_ xs (send actorQ . Just) *> send actorQ Nothing) $ \_ -> do
                let evenOrNothing (Just n) = even n
                    evenOrNothing Nothing  = True
                    go ys = do
                        maybeInt <- receiveSelect evenOrNothing q
                        case maybeInt of
                            Just y  -> go (y:ys)
                            Nothing -> pure $ reverse ys
                rs <- go []
                rs `shouldBe` evens

    describe "Inbox tryReceiveSelect" $ do
        it "returns Nothing if no message available" $ do
            q <- newInbox def
            r <- tryReceiveSelect (const True) q
            r `shouldBe` (Nothing :: Maybe Int)

        it "allows selective receive" $ do
            q <- newInbox def
            let actorQ = ActorQ q

            for_ ['a'..'z'] $ send actorQ
            r1 <- tryReceiveSelect (== 'a') q
            r1 `shouldBe` Just 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ send actorQ
            r3 <- tryReceiveSelect (== 'h') q
            r3 `shouldBe` Just 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` (['a'..'g'] <> ['i'..'z'])

            for_ ['a'..'z'] $ send actorQ
            r5 <- tryReceiveSelect (== 'z') q
            r5 `shouldBe` Just 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ send actorQ
                r7 <- tryReceiveSelect (== chr i) q
                r7 `shouldBe` Just (chr i)
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` (['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z'])

        it "returns the first element satisfying supplied predicate" $ do
            q <- newInbox def
            for_ "abcdefabcdef" $ send $ ActorQ q
            r1 <- tryReceiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` Just 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "return Nothing when there is no interesting message in the queue" $ do
            q <- newInbox def
            for_ ['a'..'y'] $ send $ ActorQ q
            r <- tryReceiveSelect (== 'z') q
            r `shouldBe` Nothing

        prop "keeps entire content if predicate was never satisfied" $ \xs -> do
            q <- newInbox def
            for_ xs $ send $ ActorQ q
            rs <- for xs $ const $ tryReceiveSelect (const False) q
            rs `shouldBe` map (const Nothing) xs
            remains <- for xs $ const $ receive q
            remains `shouldBe` (xs :: [Int])

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 10000) $ prop "try selectively reads massive number of messages concurrently" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            let evens = filter even xs :: [Int]
            withAsync (for_ xs (send actorQ . Right) *> send actorQ (Left ())) $ \_ -> do
                let evenOrLeft (Right n) = even n
                    evenOrLeft (Left _)  = True
                    go ys = do
                        maybeEither <- tryReceiveSelect evenOrLeft q
                        case maybeEither of
                            Just e  -> case e of
                                Right y -> go (y:ys)
                                Left _  -> pure $ reverse ys
                            Nothing -> go ys
                rs <- go []
                rs `shouldBe` evens

    describe "Inbox length" $ do
        prop "returns number of queued messages" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ (xs :: [Int]) $ send actorQ
            qLen <- Sv.length actorQ
            qLen `shouldBe` (fromIntegral . length) xs

        prop "returns number of remaining messages" $ \(xs, ys)  -> do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ (xs <> ys :: [Int]) $ send actorQ
            for_ xs $ const $ receive q
            qLen <- Sv.length actorQ
            qLen `shouldBe` (fromIntegral . length) ys

        prop "remains unchanged after failing selective receives" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ (xs :: [Int]) $ send actorQ
            qLenBefore <- Sv.length actorQ
            for_ xs $ const $ tryReceiveSelect (const False) q
            qLenAfter <- Sv.length actorQ
            qLenBefore `shouldBe` qLenAfter

    describe "Bounded Inbox" $ do
        prop "send blocks when the queue is full" $ \xs -> do
            let ys = 0:xs :: [Int]
            q <- newInbox $ InboxLength (fromIntegral $ length ys)
            let actorQ = ActorQ q
            marker <- newEmptyMVar
            let sender = do
                    for_ ys $ send actorQ
                    putMVar marker ()
                    send actorQ 0
            withAsync sender $ \a -> do
                takeMVar marker
                threadDelay 1000
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                _ <- receive q
                r2 <- wait a
                r2 `shouldBe` ()

        prop "trySend returns Nothing when the queue is full" $ \xs -> do
            q <- newInbox $ InboxLength (fromIntegral $ length (xs :: [Int]))
            let actorQ = ActorQ q
            for_ xs $ trySend actorQ
            r <- trySend actorQ 0
            r `shouldBe` Nothing

        prop "readling from queue makes room again" $ \xs -> do
            let ys = 0:xs :: [Int]
            q <- newInbox $ InboxLength (fromIntegral $ length ys)
            let actorQ = ActorQ q
            for_ ys $ trySend actorQ
            r1 <- trySend actorQ 0
            r1 `shouldBe` Nothing
            _ <- receive q
            r2 <- trySend actorQ 1
            r2 `shouldBe` Just ()

    describe "Concurrent operation Inbox" $ do
        prop "receives messages from concurrent senders" $ \xs -> do
            q <- newInbox def
            for_ (xs :: [Int]) $ \x -> async $ send (ActorQ q) x
            ys <- for xs $ \_ -> receive q
            sort ys `shouldBe` sort xs

        prop "can be shared by concurrent receivers" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            for_ (xs :: [Int]) $ \x -> send actorQ $ IntVal x
            for_ xs $ \_ -> send actorQ Fin
            send actorQ Fin
            let receiver msgs = do
                    msg <- receive q
                    case msg of
                        (IntVal n) -> receiver (n:msgs)
                        Fin        -> pure msgs
            as <- for xs $ \_ -> async $ receiver []
            rs <- for as wait
            (sort . concat) rs `shouldBe` sort xs

        prop "can be shared by concurrent senders and receivers" $ \xs -> do
            q <- newInbox def
            let actorQ = ActorQ q
            let sender msg = do
                    _ <- newEmptyMVar
                    send actorQ $ IntVal msg
                    pure ()
                receiver msgs = do
                    msg <- receive q
                    case msg of
                        (IntVal n) -> receiver (n:msgs)
                        Fin        -> pure msgs
            marks <- for (xs :: [Int]) $ \x -> async $ sender x
            as <- for xs $ \_ -> async $ receiver []
            for_ marks wait
            for_ xs $ \_ -> send actorQ Fin
            send actorQ Fin
            rs <- for as wait
            (sort . concat) rs `shouldBe` sort xs
