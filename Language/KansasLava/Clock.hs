{-# LANGUAGE RankNTypes, TypeFamilies, ScopedTypeVariables #-}


module Language.KansasLava.Clock where

import Data.Maybe as Maybe
import Data.Ratio

import Data.Sized.Unsigned
import Data.Sized.Signed
import Data.Sized.Ix

import Language.KansasLava.RTL
import Language.KansasLava.Utils
import Language.KansasLava.Types
import Language.KansasLava.Comb
import Language.KansasLava.Seq
import Language.KansasLava.Protocols
import Language.KansasLava.Signal
	
rate :: forall x clk . (Eq clk, Clock clk, Size x) => Witness x -> Rational -> CSeq clk Bool -> CSeq clk Bool
rate Witness n inp
  | step * 2 > 2^sz = error $ "bit-size " ++ show sz ++ " too small for punctuate Witness " ++ show n
  | n <= 0 = error "can not have rate less than or equal zero"
  | n > 1 = error "can not have rate greater than 1"
  | otherwise = runRTL $ do
	count <- newReg (0 :: Comb (Unsigned x))
	cut   <- newReg (0 :: Comb (Unsigned x))
	err   <- newReg (0  :: Comb (Signed x))
	WHEN inp $ do
	    CASE [ IF (val count .<. (fromIntegral step + val cut - 1)) $ do
		  	count := val count + 1
--		  cut := val cut
--		  err := val err
		 , OTHERWISE $ do
		  	count := 0
		  	CASE [ IF (val err .>=. 0) $ do
				cut := 1
				err := val err + fromIntegral nerr
			     , OTHERWISE $ do
				cut := 0
				err   := val err + fromIntegral perr
			     ]
		 ]
	return $ 
--		pack (val err, val count) 
		(val count .==. 0)

   where sz = fromIntegral (size (error "witness" :: x)) 
	 num = numerator n
	 dom = denominator n
	 step = floor (1 / n)
	 perr = dom - step       * num
	 nerr = dom - (step + 1) * num


-- | This is the runST of Kansas Lava.
runClocked0 :: (Clock clk, CSeq clk ~ sig)
	    => (forall clk . (Clock clk) => Clocked clk a) 
	    -> sig Bool -> sig (Enabled a)
runClocked0 sub inp0 = runClocked1 (\ _ -> sub) (packEnabled inp0 (pureS ()))

runClocked1 :: (Clock clk, CSeq clk ~ sig)
	    => (forall clk . (Clock clk) => Clocked clk a -> Clocked clk b) 
	    -> sig (Enabled a) -> sig (Enabled b)	
runClocked1 sub (Seq e_a e_as) = Seq e_b e_bs
  where
	e_b = undefined
	e_bs = undefined
{-
withClock :: (Clock clk) => (clk -> b) -> b
withClock = undefined

data X = X

default X (X)

-}