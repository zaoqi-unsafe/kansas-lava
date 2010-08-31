{-# LANGUAGE RankNTypes, ExistentialQuantification, FlexibleContexts, ScopedTypeVariables, TypeFamilies, TypeSynonymInstances, FlexibleInstances #-}
module Language.KansasLava.Trace where

import Language.KansasLava.Circuit
import Language.KansasLava.Comb
import Language.KansasLava.Entity
import Language.KansasLava.Entity.Utils
import Language.KansasLava.Reify
import Language.KansasLava.Seq
import Language.KansasLava.Signal
import Language.KansasLava.Stream hiding (head,zipWith)
import Language.KansasLava.Type
import Language.KansasLava.Utils
import Language.KansasLava.Wire

import qualified Data.Sized.Matrix as Matrix

import qualified Data.Graph.Inductive as G

import qualified Data.Reify.Graph as DRG

import Data.List
import qualified Data.Map as M
import Data.Maybe

type TraceMap k = M.Map k TraceStream

-- instance Functor TraceStream where -- can we do this with proper types?

data Trace = Trace { len :: Maybe Int
                   , inputs :: TraceMap OVar
                   , outputs :: TraceStream
                   , probes :: TraceMap OVar
--                   , circuit :: ReifiedCircuit
--                   , opts :: DebugOpts -- can see a case for this eventually
                   -- what else? keep the vhdl here?
                   }

-- Some combinators to get stuff in and out of the map
fromXStream :: forall w. (RepWire w) => w -> Stream (X w) -> TraceStream
fromXStream witness stream = TraceStream (wireType witness) [Matrix.toList $ fromWireXRep witness xVal | xVal <- toList stream ]

-- oh to have dependent types!
toXStream :: forall w. (RepWire w) => w -> TraceStream -> Stream (X w)
toXStream witness (TraceStream _ list) = fromList [toWireXRep witness $ Matrix.fromList val | val <- list]

getStream :: forall a w. (Ord a, RepWire w) => a -> TraceMap a -> w -> Stream (X w)
getStream name m witness = toXStream witness $ m M.! name

getSeq :: (Ord a, RepWire w) => a -> TraceMap a -> w -> Seq w
getSeq key m witness = shallowSeq $ getStream key m witness

addStream :: forall a w. (Ord a, RepWire w) => a -> TraceMap a -> w -> Stream (X w) -> TraceMap a
addStream key m witness stream = M.insert key (fromXStream witness stream) m

addSeq :: forall a b. (Ord a, RepWire b) => a -> Seq b -> TraceMap a -> TraceMap a
addSeq key seq m = addStream key m (witness :: b) (seqValue seq :: Stream (X b))

-- Combinators to change a trace
setCycles :: Int -> Trace -> Trace
setCycles i t = t { len = Just i }

addInput :: forall a. (RepWire a) => OVar -> Seq a -> Trace -> Trace
addInput key seq t@(Trace _ ins _ _) = t { inputs = addSeq key seq ins }

remInput :: OVar -> Trace -> Trace
remInput key t@(Trace _ ins _ _) = t { inputs = M.delete key ins }

setOutput :: forall a. (RepWire a) => Seq a -> Trace -> Trace
setOutput (Seq s _) t = t { outputs = fromXStream (witness :: a) s }

addProbe :: forall a. (RepWire a) => OVar -> Seq a -> Trace -> Trace
addProbe key seq t@(Trace _ _ _ ps) = t { probes = addSeq key seq ps }

remProbe :: OVar -> Trace -> Trace
remProbe key t@(Trace _ _ _ ps) = t { probes = M.delete key ps }

-- instances for Trace
instance Show Trace where
    show (Trace c i (TraceStream oty os) p) = unlines $ concat [[show c,"inputs"], printer i, ["outputs", show (oty,takeMaybe c os), "probes"], printer p]
        where printer m = [show (k,TraceStream ty $ takeMaybe c val) | (k,TraceStream ty val) <- M.toList m]

-- two traces are equal if they have the same length and all the streams are equal over that length
instance Eq Trace where
    (==) (Trace c1 i1 (TraceStream oty1 os1) p1) (Trace c2 i2 (TraceStream oty2 os2) p2) = (c1 == c2) && insEqual && outEqual && probesEqual
        where sorted m = sortBy (\(k1,_) (k2,_) -> compare k1 k2) $ [(k,TraceStream ty $ takeMaybe c1 s) | (k,TraceStream ty s) <- M.toList m]
              insEqual = (sorted i1) == (sorted i2)
              outEqual = (oty1 == oty2) && (takeMaybe c1 os1 == takeMaybe c2 os2)
              probesEqual = (sorted p1) == (sorted p2)

-- something more intelligent someday?
diff :: Trace -> Trace -> Bool
diff t1 t2 = t1 == t2

emptyTrace :: Trace
emptyTrace = Trace { len = Nothing, inputs = M.empty, outputs = Empty, probes = M.empty }

takeTrace :: Int -> Trace -> Trace
takeTrace i t = t { len = Just newLen }
    where newLen = case len t of
                    Just x -> min i x
                    Nothing -> i

dropTrace :: Int -> Trace -> Trace
dropTrace i t@(Trace c ins (TraceStream oty os) ps)
    | newLen > 0 = t { len = Just newLen
                     , inputs = dropStream ins
                     , outputs = TraceStream oty $ drop i os
                     , probes = dropStream ps }
    | otherwise = emptyTrace
    where dropStream m = M.fromList [ (k,TraceStream ty (drop i s)) | (k,TraceStream ty s) <- M.toList m ]
          newLen = maybe i (\x -> x - i) c

-- need to change format to be vertical
serialize :: Trace -> String
serialize (Trace c ins (TraceStream oty os) ps) = concat $ unlines [(show c), "INPUTS"] : showMap ins ++ [unlines ["OUTPUT", show $ OVar 0 "placeholder", show oty, showStrm os, "PROBES"]] ++ showMap ps
    where showMap m = [unlines [show k, show ty, showStrm strm] | (k,TraceStream ty strm) <- M.toList m]
          showStrm s = unwords [concatMap (showRepWire (witness :: Bool)) val | val <- takeMaybe c s]

deserialize :: String -> Trace
deserialize str = Trace { len = c, inputs = ins, outputs = out, probes = ps }
    where (cstr:"INPUTS":ls) = lines str
          c = read cstr :: Maybe Int
          (ins,"OUTPUT":r1) = readMap ls
          (out,"PROBES":r2) = readStrm r1
          (ps,_) = readMap r2

readStrm :: [String] -> (TraceStream, [String])
readStrm ls = (strm,rest)
    where (m,rest) = readMap ls
          [(_,strm)] = M.toList (m :: TraceMap OVar)

readMap :: (Ord k, Read k) => [String] -> (TraceMap k, [String])
readMap ls = (go $ takeWhile cond ls, rest)
    where cond = (not . (flip elem) ["INPUTS","OUTPUT","PROBES"])
          rest = dropWhile cond ls
          go (k:ty:strm:r) = M.union (M.singleton (read k) (TraceStream (read ty) ([map toXBool w | w <- words strm]))) $ go r
          go _             = M.empty
          toXBool :: Char -> X Bool
          toXBool 'T' = return True
          toXBool 'F' = return False
          toXBool _   = fail "unknown"

writeToFile :: FilePath -> Trace -> IO ()
writeToFile fp t = writeFile fp $ serialize t

readFromFile :: FilePath -> IO Trace
readFromFile fp = do
    str <- readFile fp
    return $ deserialize str

rcToGraph :: ReifiedCircuit -> G.Gr (MuE DRG.Unique) ()
rcToGraph rc = G.mkGraph (theCircuit rc) [ (n1,n2,())
                                         | (n1,Entity _ _ ins _) <- theCircuit rc
                                         , (_,_,Port _ n2) <- ins ]

-- return true if running circuit with trace gives same outputs as that contained by the trace
test :: (Run a) => a -> Trace -> (Bool, Trace)
test circuit trace = (trace == result, result)
    where result = execute circuit trace

execute :: (Run a) => a -> Trace -> Trace
execute circuit trace = trace { outputs = run circuit trace }

class Run a where
    run :: a -> Trace -> TraceStream

instance (RepWire a) => Run (CSeq c a) where
    run (Seq s _) (Trace c _ _ _) = TraceStream ty $ takeMaybe c strm
        where TraceStream ty strm = fromXStream (witness :: a) s

-- if Nothing, take whole list, otherwise, normal take with the Int inside the Just
takeMaybe :: Maybe Int -> [a] -> [a]
takeMaybe = maybe id take

{- eventually
instance (RepWire a) => Run (Comb a) where
    run (Comb s _) (Trace c _ _ _) = (wireType witness, take c $ fromXStream witness (fromList $ repeat s))
        where witness = (error "run trace" :: a)
-}

instance (Run a, Run b) => Run (a,b) where
    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y) t = TraceStream (TupleTy [ty1,ty2]) $ zipWith (++) strm1 strm2
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t

instance (Run a, Run b, Run c) => Run (a,b,c) where
    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y,z) t = TraceStream (TupleTy [ty1,ty2,ty3]) (zipWith (++) strm1 $ zipWith (++) strm2 strm3)
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t
              TraceStream ty3 strm3 = run z t

instance (RepWire a, Run b) => Run (Seq a -> b) where
    run fn t@(Trace c ins _ _) = run (fn input) $ t { inputs = M.delete key ins }
        where key = head $ sort $ M.keys ins
              input = getSeq key ins (witness :: a)

{- combinators for working with traces
-- assuming ReifiedCircuit has probe data in it
mkTraceRC :: (..) => ReifiedCircuit -> Trace

-- this is just Eq, but maybe instead of Bool some kind of detailed diff
unionTrace :: Trace -> Trace -> Trace
remove :: OVar -> Trace -> Trace

-- testing?

-- take a trace and a path, compare trace to other serialized traces residing in that path
unitTest :: FilePath -> Trace -> IO Bool -- or some rich exit code
unitTest' :: (..) => FilePath -> a -> (a -> b) -> IO (Bool, b) -- same
thing, but builds trace internally

-- create tarball for modelsim, much like mkTestbench
genSim :: FilePath -> Trace -> IO ()

-- create tarball for use on togo, including the SimpleWrapper
genWrapper :: FilePath -> Trace -> IO ()

-- output formats
latexWaveform :: Trace -> String
truthTable :: Trace -> String -- or some truth table structure
vcd :: Trace -> String -- or maybe FilePath -> Trace -> IO ()
vhdl :: Trace -> String
-}