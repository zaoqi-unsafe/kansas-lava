{-# LANGUAGE FlexibleInstances,TypeFamilies, UndecidableInstances, PatternGuards,ParallelListComp #-}
module Language.KansasLava.VHDL where


-- import qualified Language.KansasLava.Entity as E
import Language.KansasLava.Reify
import Language.KansasLava.Signal
import Language.KansasLava.IO
import Language.KansasLava.Entity hiding (name)


import Data.Reify.Graph

import Text.PrettyPrint
import Data.List(intersperse)
import Data.Bits
import Data.List(mapAccumL)
import Control.Monad(liftM)
import Data.Maybe(catMaybes,fromJust)

import Language.KansasLava.Type
import qualified Data.Set as Set


fixed_ports = []
--  [("clk,rst", "in", "std_logic")]           --- error, hack?


vhdlCircuit :: (REIFY o) =>  [ReifyOptions] -> String -> o -> IO String
vhdlCircuit opts name circuit = do
{-
  let (ins',g) = output' circ
  let ins = map fst ins'
  -- for debugging (not part of VHDL output)

--  print (ins,outs)
  -- This could be better
-}
  (ReifiedCircuit nodes ins outs' types) <- reifyCircuit opts circuit
                        -- a sort of comsumer for the entity being generated
  -- for debugging (not part of VHDL output)
  print (nodes,ins,outs',types)

  let findTyFor :: QVar -> BaseTy
      findTyFor v = case lookup v types of
		    Nothing -> error $ "can not find type for : " ++ show v
		    Just ty -> ty

--  print $ map findTyFor [(-1,v) | v <- ins ]
  print $ map findTyFor [(i,v) | (_,Port v i) <- outs' ]

  let ports = fixed_ports ++
              -- need size info for each input, to declare length of std_logic_vector
            [ (nm,"in",vhdlTypes (findTyFor (Source,Var nm))) | Var nm <- ins] ++
              -- need size info for each output, to declare length of std_logic_vector
            [ (nm,"out",vhdlTypes (findTyFor (i,v))) | (Var nm,Port v i) <- outs'] ++
            [ (nm,"out",vhdlTypes (findTyFor (Source,v))) | (Var nm,Pad v) <- outs'] ++
            []

  let ent = VhdlEntity name [] ports

  let arch = VhdlArchitecture name (decls findTyFor nodes) (insts types nodes ++ finals outs')
  let rendered = render $ pretty ent $$ pretty arch
  putStrLn rendered
  return rendered

ports :: (Graph (Entity a)) -> [PortDescriptor]
ports (Graph nodes out) =
--  [(n,"in","std_logic_vector") | (i,Pad (Var n)) <- nodes, notConst n] ++
 -- [("clk,rst", "in", "std_logic")] ++
  [("sig" ++ show out, "out", "std_logic_vector")]

{-
notConst "low" = False
notConst "high" = False
notConst _ = True
-}

vhdlTypes :: BaseTy -> String
vhdlTypes B     = "std_logic"
vhdlTypes CB	= "std_logic"			-- control bit
vhdlTypes ClkTy	= "std_logic"			-- control bit
vhdlTypes RstTy	= "std_logic"			-- control bit
vhdlTypes (S n) = "std_logic_vector(" ++ show (n - 1) ++ " downto 0)"
vhdlTypes (U n) = "std_logic_vector(" ++ show (n - 1) ++ " downto 0)"

decls :: (QVar -> BaseTy) -> [(Unique,Entity ty Uq)] -> [DeclDescriptor]
decls tyEnv nodes =
    -- need size info for each output, to declare length of std_logic_vector
    [ SigDecl (sig (Port (Var n) (Uq i))) (vhdlTypes (tyEnv (Uq i,Var n))) Nothing
                          | (i,Entity _ outputs _ _) <- nodes
                          , Var n <- outputs
                          ] ++
    concat [ [ SigDecl (sig (Port (Var n) (Uq i)) ++ "_next") (vhdlTypes (tyEnv (Uq i,Var n))) Nothing
     	     ]
           | (i,Entity (Name "Lava" "delay") [Var n] _ _) <- nodes
           ] ++
    concatMap memDecl nodes
--     concat [ [ TypeDecl (sig (Port (Var n) (Uq i)) ++ "_ram")
--                         -- clearly neds to calculate this...
--                         "array(0 to 100) of std_logic_vector(32 downto 0)"
--              , SigDecl (sig (Port (Var n) (Uq i)))
--                        (sig (Port (Var n) (Uq i)) ++ "_ram") Nothing]
--              | (i,Entity (Name "Lava" "BRAM") [Var n] _ _) <- nodes
--              ]
  where memDecl (i,Entity (Name "Lava" "BRAM") [Var n] _ _) =
          let asize = baseTypeLength $ tyEnv (Uq i, Var "ain")
              dsize = baseTypeLength $ tyEnv (Uq i, Var "din")
              outputType = vhdlTypes $ tyEnv (Uq i, Var "din")
          in [ TypeDecl (sig (Port (Var n) (Uq i)) ++ "_ram_type")
                        -- clearly neds to calculate this...
                        ("array(0  to " ++ show (2^asize)  ++ ") of std_logic_vector(" ++ show (dsize - 1)  ++ " downto 0)")
             , SigDecl (sig (Port (Var n) (Uq i)) ++ "_ram")
                       (sig (Port (Var n) (Uq i)) ++ "_ram_type") Nothing
             , SigDecl (sig (Port (Var n) (Uq i)))
                       outputType Nothing
             ]
        memDecl _ = []



finals :: [(Var,Driver Uq)] -> [Inst]
finals args = [ Assign n (sig x) | (Var n,x) <- args ]

insts :: Show ty => TypeEnv -> [(Unique,Entity ty Uq)] -> [Inst]
insts tyEnv nodes = concat [
{-        if i == root
        then [ Assign n (sig x) | (Var n,x) <- ins ]
        else -} mkInst tyEnv i ent
     | (i,ent@(Entity _ outs ins _)) <- nodes ] ++
     (synchronous tyEnv nodes)

fixName ".&." = "AND"
fixName "xor2" = "XOR"
fixName ".|." = "OR"
fixName xs    = xs

-- infix specials
isSpecialName :: Name -> Maybe String
isSpecialName (Name "Bool" "+") = return "XOR"
isSpecialName (Name "Bool" "*") = return "AND"
isSpecialName _ = Nothing


specials =
  [(Name moduleName lavaName,
         (vhdlName, Just "std_logic_vector"))
   | moduleName <- ["Unsigned", "Signed","Int"]
  , (lavaName,vhdlName) <-
    [("+","+"), ("-","-")]] ++
  [(Name moduleName lavaName,
         (vhdlName, Nothing))
   | moduleName <- ["Unsigned", "Signed","Bool"]
  , (lavaName,vhdlName) <-
    [(".<.","<"), (".>.",">"),(".==.","=")]] ++

  [(Name moduleName lavaName,
         (vhdlName, Just "std_logic_vector"))
   | moduleName <- ["Unsigned", "Signed"]
  , (lavaName,vhdlName) <-
    [(".|.","or"), (".&.","and"), (".^.","xor")]] ++
  [(Name moduleName lavaName,
         (vhdlName, Nothing))
   | moduleName <- ["Bool"]
  , (lavaName,vhdlName) <-
    [("or2","or"), ("and2","and"), ("xor2","xor")]]





mkInst :: TypeEnv -> Int -> Entity ty Uq -> [Inst]
-- mkInst _ e = error $ show e
--    mkInst i (Pad (Var "low")) = Assign (sig i) "'0'"
--    mkInst i (Pad (Var "high")) = Assign (sig i) "'1'"

mkInst tyEnv i e@(Entity n@(Name mod nm) [Var "o0"] [(Var "i0",x),(Var "i1",y)] _)
        | Just (nm',cast) <- lookup n specials =
          [ BuiltinInst (sig (Port (Var "o0") (Uq i)))
                        (sigTyped (getTy tyEnv i "i0") x)
                        nm'
                        (sigTyped (getTy tyEnv i "i1") y) cast
          ]

{-
mkInst tyEnv i e@(Entity nm [Var "o0"] [(Var "i0",x),(Var "i1",y)] _)
	| Just op <- isSpecialName nm
	  = [ BuiltinInst (sig (Port (Var "o0") (Uq i)))
                        (sig x)
                        (op)
                        (sig y) Nothing
            ]
mkInst tyEnv i e@(Entity (Name mod nm) [Var "o0"] [(Var "i0",x),(Var "i1",y)] _)
        | mod == "Bool" && nm `elem` (["xor",".&.",".|."] ++ ["xor2","and2","or2"])
        = [ BuiltinInst (sig (Port (Var "o0") (Uq i)))
                        (sig x)
                        (fixName nm)
                        (sig y) Nothing
          ]

mkInst tyEnv i e@(Entity (Name mod nm) [Var "o0"] [(Var "i0",x),(Var "i1",y)] _)
        | {- mod == "Unsigned"  && -} nm `elem` ["+", "-"] =
          [ BuiltinInst (sig (Port (Var "o0") (Uq i)))
                        (sigTyped (getTy tyEnv i "i0") x)
                        (fixName nm)
                        (sigTyped (getTy tyEnv i "i1") y) (Just "std_logic_vector")
          ]

-}



-- BUG: o vs o0
-- Delay Circuits
mkInst tyEnv i e@(Entity (Name "Lava" "delay") [Var "o"]
			[ (Var "clk",clk)
			, (Var "rst",rst)
			, (Var "init",x)
			, (Var "i",y)
			] _) =
          [ Assign input (sig y) ]
  where output = sig (Port (Var "o") (Uq i))
        input =  output ++ "_next"

-- Muxes
mkInst tyEnv i e@(Entity (Name "Bool" "mux2") [Var "o0"] [(Var "c",c),(Var "t",t),(Var "f",f)] _)
	= [ CondAssign (sig (Port (Var "o0") (Uq i)))
                       [(sigTyped (getTy tyEnv i "f") f, sigTyped (getTy tyEnv i "c") c ++ "= '0'")]
                       (sigTyped (getTy tyEnv i "t") t)
         ]
mkInst tyEnv i e@(Entity (Name "Bool" "mux2") x y z) = error $ show (x,y)

mkInst tyEnv i e@(Entity (Name "Lava" "concat") [Var "o"] inps _) =
                  [Assign (sig (Port (Var "o") (Uq i))) val]
  where val = concat $ intersperse "&"
              -- Note the the layout is reversed
              [sigTyped (getTy tyEnv i v) sig | (Var v, sig) <- reverse inps]


mkInst _ _ e@(Entity (Name "Lava" "BRAM") _ _ _) = []

mkInst tyEnv i e@(Entity (Name "Lava" "index") [Var "o"] [(Var "i", input),(Var "index",idx)] _) =
  [Assign (sig (Port (Var "o") (Uq i)))
          (sig input ++ "(" ++ sig idx ++ ")")]

mkInst tyEnv i e@(Entity (Name "Lava" "slice") [Var "o"]
                  [(Var "i", input),(Var "low",low),(Var "high",high)] _) =
  [Assign (sig (Port (Var "o") (Uq i)))
          (sig input ++ "(" ++ sig high ++ " downto " ++ sig low ++ ")")]


-- Catchall for everything else
mkInst tyEnv i e@(Entity (Name mod nm) outputs inputs _) =
          [ Inst ("inst" ++ show i) nm
                []
                ( [ (n,sig (Port (Var n) (Uq i))) | Var n <- outputs ] ++
                  [ (n,sigTyped (getTy tyEnv i n) x) | (Var n,x) <- inputs ]
                )
          ]


{-
        mkInst tyEnv i (Entity (Name _ "mux") inputs) =
          inst i "mux" "o" ["s","d0","d1"] inputs
        mkInst tyEnv i (Entity (Name _ "not") [j]) =
          Assign (sig i) ("not " ++  (sig j))
        mkInst tyEnv i (Entity (Name _ "xor2") inputs) =
          inst i "xor2" "o" ["i0","i1"] inputs
        mkInst tyEnv i (Entity (Name "Bool" ".&.") inputs) =
          inst i "and2" "o" ["i0","i1"] inputs
        mkInst tyEnv i (Entity (Name _ "xor") inputs) =
          inst i "xor2" "o" ["i0","i1"] inputs
        mkInst tyEnv i (Entity (Name "$" n) inputs) = Comment $ show (n,inputs)
        mkInst tyEnv i (Pad (Var n)) = Assign (sig i) n
        mkInst tyEnv i (Lit x) = Assign (sig i) ("conv_std_logic(" ++ show x ++ ")")
        mkInst tyEnv i (Entity (Name "Int" "+") [l,r]) = Assign (sig i)  (sig l ++ " + " ++ sig r)
        mkInst tyEnv i (Entity (Name "Int" "fromInteger") [x]) = Assign (sig i) (sig x)

        mkInst tyEnv i ent = error $ "BAD INSTRUCTION: " ++ show i ++ " " ++ show (ent,nodes)
-}
sig :: Driver Uq -> String
sig (Port i Sink)   = show i	-- pre normalized
sig (Port i Source) = show i
sig (Port i (Uq v)) = "sig_" ++ show i ++ "_" ++ show v
sig (Pad (Var n)) = n
sig (Lit n) = show n

-- sigTyped allows the type casts, especially for literals.
sigTyped (U width) (Lit n) = "to_unsigned(" ++ show n ++ "," ++ show width ++ ")"
sigTyped (S width) (Lit n) = "to_signed(" ++ show n ++ "," ++ show width ++ ")"
sigTyped B         (Lit 0) = "'0'"
sigTyped B         (Lit 1) = "'1'"
sigTyped B     s = sig s
sigTyped (U _) s = "unsigned(" ++ sig s ++ ")"
sigTyped (S _) s = "signed(" ++ sig s ++ ")"
sigTyped ClkTy s = sig s
sigTyped RstTy s = sig s

sigTyped ty s = error $ "sigtyped :" ++ show ty ++ "/" ++ show s


-- getType
getTy tyEnv i var = maybe (error "VHDL.getTy") id (lookup (Uq i, Var var) tyEnv)


--        inst i entity o formals actuals =
--          Inst ("inst" ++ show i) entity [] ((o,sig i):(zip formals (map sig actuals)))


--implode' :: Ex (a,b) -> Signal (a,b)
--implode' = implode
{-
instance Compile b => Compile (Signal a -> b) where
  compile f = compile (f port)
    where port = Signal (error "input port") $ Wire $ Pad (Var ("input" ++ show (pos f)))
  pos f = pos (undefined `asTypeOf` f undefined) + 1
-}


type GenericDescriptor = (String,String,Maybe String)
-- (name,type,default)
type PortDescriptor = (String,String,String)
-- Name, Mode (in or out),Type
data DeclDescriptor = SigDecl String String (Maybe String) -- name, type, default
                    | TypeDecl String String -- name, value
                    deriving Show


data VhdlStruct = VhdlEntity String [GenericDescriptor] [PortDescriptor]
                | VhdlArchitecture String -- VhdlEntity
                  [DeclDescriptor]
                  [Inst]
            deriving Show

data Inst = Assign String String
          -- a <= b;
          | BuiltinInst String String String String (Maybe String) -- a,b,op,c,conv
          -- a <= conv (b op c);
          | Inst String String [(String,String)] [(String,String)]
            -- String, VhdlEntity, DeclDescriptor Map, PortDescriptor Map
	  | Cond String	-- condition
		 [Inst]
		 [Inst]
	  | CondAssign String
		        [(String,String)]	-- (Val, Cond)
			String
          | Comment String
          | Process [String]
		    [Inst]
          deriving Show


class Pretty a where
  pretty :: a -> Doc

instance Pretty VhdlStruct where
  pretty (VhdlEntity name generics ports) =
    imports $$
    (text "entity" <+> text name <+> text "is") $$
    gdoc $$
    (nest 2 ((text "port") <+> parens pdoc) <> semi) $$
    (text "end entity") <+> text name <> semi
   where pdoc = (cat $ punctuate semi $ map printPort ports)
         printPort (n,mode,ty) = text n <+> colon <+> text mode <+> text ty
         gdoc | null generics = empty
              | otherwise = nest 2 $ (text "generic") <+>
                                     parens (vcat $ map printGen generics)
         printGen (n,ty,Nothing) = text n <+> colon <+> text ty <> semi
         printGen (n,ty,Just def) = text n <+> colon <+> text ty <+> text ":=" <+> text def <> semi
         imports = vcat $ map text ["library IEEE;",
                                    "use IEEE.STD_LOGIC_1164.ALL;",
                                    "use IEEE.NUMERIC_STD.ALL;",
                                    "use work.all;"]


  pretty (VhdlArchitecture entity decls insts) =
      (text "architecture str of") <+> text entity <+> text "is" $$
      ddoc $$
      hang (text "begin") 2 (vcat $ map pretty insts) $$
      text "end architecture" <> semi
   where ddoc = vcat $ map printDecl decls
         printDecl (SigDecl name ty Nothing) =
           text "signal" <+> text name <+> colon <+> text ty <> semi
         printDecl (SigDecl  name ty (Just def)) =
           text "signal" <+> text name <+> colon <+> text ty <+> text ":=" <+> text def <> semi
         printDecl (TypeDecl name ty) =
           text "type" <+> text name <+> text "is" <+> text ty <> semi


instance Pretty Inst where
  pretty (Assign a b) = text a <+> text "<=" <+> text b <> semi
  pretty (BuiltinInst a b op c Nothing) = text a <+> text "<=" <+> text b <+> text op <+> text c <> semi
  pretty (BuiltinInst a b op c (Just conv)) = text a <+> text "<=" <+> text conv <> parens (text b <+> text op <+> text c) <> semi
  pretty (Cond cond ifT []) =
    text "if" <+> text cond <+> text "then" $$
      nest 4 (vcat $ map pretty ifT) $$
      (text "end if") <> semi
  pretty (Cond cond ifT ifF) =
    text "if" <+> text cond <+> text "then" $$
      nest 4 (vcat $ map pretty ifT) $$
      (text "else") $$
      nest 4 (vcat $ map pretty ifF) $$
      (text "end if") <> semi

  pretty (Inst lab ent generics ports) =
    text lab <+> colon <+> text "entity" <+> text ent $$
      nest 2 gmap $$
      nest 2 pmap <> semi
    where gmap | null generics = empty
               | otherwise = text "generic map" <> parens (hcat $ intersperse comma $ map printMap generics)
          pmap | null ports = empty
               | otherwise = text "port map" <> parens (hcat $ intersperse comma $ map printMap ports)
          printMap (p,t) = text p <+> text "=>" <+> text t
  pretty (Comment str) = text "--" <+> text str
  pretty (Process watch insts) =
	hang (text "process" <+> parens (hcat $ intersperse comma $ map text watch)
	 	       <+> text "is") 2
	   (hang (text "begin") 2 (vcat $ map pretty insts) $$
	   text "end process" <> semi)

  pretty (CondAssign a alts def) =
	text a <+> text "<=" <+> (hsep $ map prettyAlt alts) <+> text def <> semi
    where prettyAlt (val,cond) = text val <+> text "when" <+> parens (text cond) <+> text "else"


--   '0' when (Sreg0 = S2 and  X='1') else

{-
	(text "architecture str of") <+> text entity <+> text "is" $$
      ddoc $$
      hang (text "begin") 2 (vcat $ map pretty insts) $$
      text "end architecture" <> semi
-}


-- The 'synchronous' function generates a synchronous process for the
-- delay elements
synchronous tyEnv nodes
  | null delays && null brams  = []
  | otherwise = [Process ([sig clk, sig rst] ++  inputs ++ bramWE ++  bramData)
                       [ Cond ("rising_edge(" ++ sig clk ++ ")")
		         ((if null delays
                          then []
                          else
                            [Cond (sig rst ++ "='1'")
		             (zipWith Assign outputs inits)
                             (zipWith Assign outputs inputs)
	                    ])  ++
                         [(Cond (we ++ "='1'")
                                [Assign target dat,
                                 Assign o "(others => '0')"]
                                [Assign o target])
                           | we <- bramWE
                           | o <- bramOuts
                           | target <- bramTargets
                           | dat <- bramData
                          ]) -- Then
                         [] -- Else
	               ]
                     ]
  where delays = [(i,e) | (i,e@(Entity (Name "Lava" "delay") [Var n] _ _)) <- nodes]
        ((_,d):_) = delays
        outputs = [sig (Port (Var "o") (Uq i)) | (i,_) <- delays]
        inputs = [o ++ "_next" | o <- outputs]
        -- inits = map sig $ catMaybes (map (lookupInput "init" . snd) delays)
        inits = [sigTyped (getTy tyEnv i "init") (fromJust (lookupInput "init" e))
                 | (i,e@(Entity (Name "Lava" "delay") [Var n] _ _)) <- delays]

        Just clk  = lookupInput "clk" (head (map snd (delays ++ brams)))
        Just rst =  lookupInput "rst" (head (map snd (delays ++ brams)))
        lookupInput i (Entity _ outputs inputs _) = lookup (Var i) inputs

        brams = [(i,e) | (i,e@(Entity (Name "Lava" "BRAM") [Var n] _ _)) <- nodes]
        bramOuts =[sig (Port (Var "o") (Uq i)) | (i,_) <- brams]
        bramSigs = [(sig (Port (Var n) (Uq i)) ++ "_ram")
                      | (i,Entity _ [Var n] _ _) <- nodes]
        bramAddr = ["conv_integer(" ++ sig (fromJust (lookupInput "ain" e)) ++ ")"
                   | (i,e) <- brams]
        bramData = [sig (fromJust (lookupInput "din" e))
                   | (i,e) <- brams]
        bramWE = [sig (fromJust (lookupInput "we" e))
                   | (i,e) <- brams]
        bramTargets = [s ++ "(" ++ a ++ ")" |  s <- bramSigs | a <- bramAddr]





