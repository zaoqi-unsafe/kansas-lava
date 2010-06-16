{-# LANGUAGE TypeFamilies, ExistentialQuantification, FlexibleInstances, UndecidableInstances, FlexibleContexts,
    ScopedTypeVariables, MultiParamTypeClasses, FunctionalDependencies,ParallelListComp  #-}

module Language.KansasLava.Seq where

import Data.Word
import Data.Int
import Data.Bits
import Data.List

import Data.Reify
import qualified Data.Traversable as T
import Language.KansasLava.Type
import Language.KansasLava.Signal

import Language.KansasLava.Entity
import Language.KansasLava.Stream as S

import Control.Applicative
import Data.Sized.Unsigned as UNSIGNED
import Data.Sized.Signed as SIGNED
import Data.Sized.Sampled as SAMPLED
import Data.Sized.Arith as Arith
import qualified Data.Sized.Matrix as M
import Data.Sized.Ix as X

import Language.KansasLava.Comb
import Data.List as List
import Language.KansasLava.Wire

-----------------------------------------------------------------------------------------------

-- These are sequences of values over time.
-- We assume edge triggered logic (checked at (typically) rising edge of clock)
-- This clock is assumed known, based on who is consuming the list.
-- Right now, it is global, but we think we can support multiple clocks with a bit of work.

data Seq a = Seq (Stream (X a)) (D a)

seqValue :: Seq a -> Stream (X a)
seqValue (Seq a d) = a

seqDriver :: Seq a -> D a
seqDriver (Seq a d) = d

instance forall a . (RepWire a, Show a) => Show (Seq a) where
	show (Seq vs _)
         	= unwords [ showRepWire (undefined :: a) x ++ " :~ "
                          | x <- take 20 $ toList vs
                          ] ++ "..."

instance forall a . (Wire a, Eq a) => Eq (Seq a) where
	-- Silly question; never True; can be False.
	(Seq x _) == (Seq y _) = error "undefined: Eq over a Seq"

deepSeq :: D a -> Seq a
deepSeq d = Seq (error "incorrect use of shallow Seq") d

shallowSeq :: Stream (X a) -> Seq a
shallowSeq s = Seq s (D $ Pad $ Var "incorrect use of deep Seq")

errorSeq ::  forall a . (Wire a) => Seq a
errorSeq = liftS0 errorComb

instance Signal Seq where
  liftS0 ~(Comb a e) = Seq (pure a) e

  liftS1 f ~(Seq a ea) = {-# SCC "liftS1Seq" #-}
    let 
	Comb _ eb = f (deepComb ea)
	f' a = let ~(Comb b _) = f (shallowComb a) 
	       in b
   in Seq (fmap f' a) eb

  -- We can not replace this with a version that uses packing,
  -- because *this* function is used by the pack/unpack stuff.
  liftS2 f ~(Seq a ea) ~(Seq b eb) = Seq (S.zipWith f' a b) ec
      where
	Comb _ ec = f (deepComb ea) (deepComb eb)
	f' a b = let ~(Comb c _) = f (shallowComb a) (shallowComb b) 
	         in c

  liftSL f ss = Seq (S.fromList
		    [ combValue $ f [ shallowComb x | x <- xs ]
		    | xs <- List.transpose [ S.toList x | Seq x _ <- ss ]
		    ]) 
		    (combDriver (f (map (deepComb . seqDriver) ss)))


----------------------------------------------------------------------------------------------------

-- Small DSL's for declaring signals

toSeq :: (Wire a) => [a] -> Seq a
toSeq xs = shallowSeq (S.fromList (map optX (map Just xs ++ repeat Nothing)))

toSeq' :: (Wire a) => [Maybe a] -> Seq a
toSeq' xs = shallowSeq (S.fromList (map optX (xs ++ repeat Nothing)))

toSeqX :: forall a . (Wire a) => [X a] -> Seq a
toSeqX xs = shallowSeq (S.fromList (xs ++ map (optX :: Maybe a -> X a) (repeat Nothing)))

takeThenSeq :: Int -> Seq a -> Seq a -> Seq a
takeThenSeq n sq1 sq2 = shallowSeq (S.fromList (take n (S.toList (seqValue sq1)) ++  (S.toList (seqValue sq2))))

encSeq :: (Wire a) =>  (Char -> Maybe a) -> String -> Seq a
encSeq enc xs = shallowSeq (S.fromList (map optX (map enc xs ++ repeat Nothing)))

encSeqBool :: String -> Seq Bool
encSeqBool = encSeq enc 
	where enc 'H' = return True
	      enc 'L' = return False
	      enc  _   = Nothing

showStreamList :: forall a . (RepWire a) => Seq a -> [String]
showStreamList ss = 
	[ showRepWire (undefined :: a) x
	| x <- toList (seqValue ss)
	]

fromSeq :: (Wire a) => Seq a -> [Maybe a]
fromSeq = fmap unX . toList . seqValue

fromSeqX :: (Wire a) => Seq a -> [X a]
fromSeqX = toList . seqValue

-----------------------------------------------------------------------------------
-- TODO: move into its own module
-- Take the shallow from the first, and the deep from the second

class Dual a where
  dual :: a -> a -> a

instance Dual (Seq a) where
  dual ~(Seq a _) ~(Seq _ eb) = Seq a eb

instance Dual (Comb a) where
  dual ~(Comb a _) ~(Comb _ eb) = Comb a eb

instance (Dual a, Dual b) => Dual (a,b) where
	dual ~(a1,b1) ~(a2,b2) = (dual a1 a2,dual b1 b2)

instance (Dual a, Dual b,Dual c) => Dual (a,b,c) where
	dual ~(a1,b1,c1) ~(a2,b2,c2) = (dual a1 a2,dual b1 b2,dual c1 c2)
	
instance (Dual b) => Dual (a -> b) where
	dual f1 f2 = \ x -> dual (f1 x) (f2 x)

-----------------------------------------------------------------------------------

-- Monomorphic box round wires.
data IsRepWire = forall a . (RepWire a) => IsRepWire (Seq a)

-- The raw data
showBitfile :: [IsRepWire] -> [String]
showBitfile streams = 
	      [ concat bits 
	      | bits <- bitss
	      ]
	where	bitss = transpose $ map (\ (IsRepWire a) -> showSeqBits a) streams


showBitfileInfo :: [IsRepWire] -> [String]
showBitfileInfo streams = 
	      [  "(" ++ show n ++ ") " ++ joinWith " -> " 
		 [ v ++ "/" ++ b
	         | (b,v) <- zip bits vals
	         ]
	      | (n,bits,vals) <- zip3 [0..] bitss valss
	      ]
	where
		joinWith _ [] = []
		joinWith sep xs = foldr1 (\ a b -> a ++ sep ++ b) xs
		bitss = transpose $ map (\ (IsRepWire a) -> showSeqBits a) streams
		valss = transpose $ map (\ (IsRepWire a) -> showSeqVals a) streams

showSeqBits :: forall a . (RepWire a) => Seq a -> [String]
showSeqBits ss = [ (map showX $ reverse $ M.toList $ (fromWireXRep witness (i :: X a)))
		 | i <- fromSeqX (ss :: Seq a)
       	         ]
       where showX b = case unX b of
			Nothing -> 'X'
			Just True -> '1'
			Just False -> '0'
             witness = error "witness" :: a

showSeqVals :: forall a . (RepWire a) => Seq a -> [String]
showSeqVals ss = [ showRepWire witness i
	 	 | i <- fromSeqX (ss :: Seq a)
       	         ]

     where witness = error "witness" :: a


{-

	let witness :: a
	    witness = error "witness for writeBitfile"
	writeFile filename 
	      $ unlines 
	      $ take count
	      $ [ (map showX $ reverse $ M.toList $ (fromWireXRep witness (i :: X a)))
			++ " -- " ++ showRepWire witness i
		
		| i <- fromSeqX (ss :: Seq a)
       	        ]

-}