module Tail2Futhark.Compile (compile) where

import APLAcc.TAIL.AST as T -- the TAIL AST
import Tail2Futhark.Futhark.AST as F -- the futhark AST
import GHC.Float (double2Float)
import Data.List
import Data.Maybe
import Data.Char

compile :: T.Program -> F.Program
compile e = builtins ++ takeFuns ++ [(RealT, "main", [], (compileExp e))]
  where takes = nub $ getTakes (compileExp e)
        takeFuns = map makeTake . catMaybes . map getType $ takes


getTakes (FunCall ident _) = maybeToList $ stripPrefix "take" ident--if isPrefixOf "take" ident then [ident] else []
getTakes (F.Let _ e1 e2) = getTakes e1 ++ getTakes e2
getTakes (Index e es) = getTakes e ++ concat (map getTakes es)
getTakes (F.Neg e) = getTakes e
getTakes (Array es) = concat $ map getTakes es
getTakes (BinApp _ e1 e2) = getTakes e1 ++ getTakes e2
getTakes (Map _ e) = getTakes e
getTakes (Filter _ e) = getTakes e
getTakes (Scan _ e1 e2) = getTakes e1 ++ getTakes e2
getTakes (Reduce _ e1 e2) = getTakes e1 ++ getTakes e2


builtins :: [F.FunDecl]
builtins = [makeTake (ArrayT (ArrayT F.IntT))]

makeTake :: F.Type -> F.FunDecl
makeTake tp = (tp,("take" ++ show (rank tp) ++ ppTp (baseType tp)),[(ArrayT F.IntT, "dims"),(tp,"x")],takeBody)
  where ppTp :: F.Type -> String
        ppTp tp = case tp of F.IntT -> "int"
                             F.RealT -> "real"
                             F.BoolT -> "bool"
                             F.CharT -> "char"
getType s 
  | suffix `elem` ["int","real","bool","char"]
  , Just rank <- rank
  = Just $ makeArrTp (readBType suffix) rank
  | otherwise = Nothing
  where (prefix,suffix) = span isDigit s
        rank | [] <- prefix = Nothing | otherwise = Just (read prefix :: Integer)
        readBType tp = case tp of "int" -> F.IntT
                                  "real" -> F.RealT
                                  "bool" -> F.BoolT
                                  "char" -> F.CharT


takeBody :: F.Exp
takeBody = undefined

-- Expressionis--
compileExp :: T.Exp -> F.Exp
compileExp (T.Var ident) = F.Var ("t_" ++ ident)
compileExp (I int) = Constant (Int int)
compileExp (D double) = Constant (Float (double2Float double)) -- isn't this supporsed to be real??????????
compileExp (C char)   = Constant (Char char)
compileExp Inf = Constant (Float (read "Infinity"))
compileExp (T.Neg exp) = F.Neg (compileExp exp)
compileExp (T.Let id t e1 e2) = F.Let (Ident ("t_" ++ id)) (compileExp e1) (compileExp e2) -- Let
compileExp (T.Op ident instDecl args) = compileOpExp ident instDecl args
compileExp (T.Fn _ _ _) = error "Fn not supported"
compileExp (Vc exps) = Array(map compileExp exps)


compileOpExp ident instDecl args = case ident of
  "reduce" -> compileReduce instDecl args
  "eachV"  -> compileEachV instDecl args
  "firstV" -> compileFirstV instDecl args
  "shapeV" -> makeShape 1 args 
  "shape"  -> compileShape instDecl args 
  _
   -- | [e]      <- args
   -- , Just fun <- convertFun ident
   -- -> F.FunCall fun [compileExp e]
    | [e1,e2]  <- args
    , Just op  <- convertBinOp ident
    -> F.BinApp op (compileExp e1) (compileExp e2)
    | Just fun <- convertFun ident
    -> F.FunCall fun $ map compileExp args
    | otherwise       -> error $ ident ++ " not supported"
--compileOpExp "addi" _ [e1,e2] = F.BinApp F.Plus (compileExp e1) (compileExp e2)
--compileOpExp "addd" _ [e1,e2] = F.BinApp F.Plus (compileExp e1) (compileExp e2)
--compileOpExp "i2d" _ [e]      = F.FunCall "toReal" [compileExp e]
--compileOpExp ident instDecl args = error $ ident ++ " not supported"

convertFun fun = case fun of
  "i2d"    -> Just "toReal"
  "iotaV"  -> Just "iota"
  _     -> Nothing

convertBinOp op = case op of
  "addi" -> Just F.Plus
  "addd" -> Just F.Plus
  _      -> Nothing

-- AUX functions --
makeShape rank args
  | [e] <- args = F.Array $ map (\x -> FunCall "size" [Constant (Int x), compileExp e]) [0..rank-1]
  | otherwise = error "shape takes one argument"
--  | [e] <- args =  F.Map (F.Fn F.IntT [(F.IntT, "d")] (FunCall "size" [F.Var "d", compileExp e])) dims
--  | otherwise = error "shape takes one argument"
--    where dims = F.Map (F.Fn F.IntT [(F.IntT,"x")] (BinApp Plus (F.Var "x") (F.Neg (Constant (Int 1))))) (FunCall "iota" [Constant (Int rank)]) 

compileShape (Just(_,[len])) args = makeShape len args
compileShape Nothing args = error "Need instance declaration for shape"

compileFirstV _ args
  | [e] <- args = F.Index (compileExp e) [F.Constant (F.Int 0)]
  | otherwise = error "firstV takes one argument"

--compileEachV :: Maybe InstDecl -> T.Exp -> F.Exp -> F.Exp
compileEachV Nothing _ = error "Need instance declaration for eachV"
compileEachV (Just ([intp,outtp],[len])) [kernel,array] = Map kernelExp (compileExp array)
   where kernelExp = compileKernel kernel (makeBTp outtp) 

--compileReduce :: Maybe InstDecl -> T.Exp -> F.Exp -> F.Exp -> F.Exp
compileReduce Nothing _ = error "Need instance declaration for reduce"
compileReduce (Just ([tp],[rank])) [kernel,id,array]
  | rank == 0 = Reduce kernelExp idExp arrayExp
  | otherwise = error "Reduce operation - Not supported" 
    where kernelExp = compileKernel kernel (makeArrTp (makeBTp tp) rank)
          idExp = compileExp id
          arrayExp = compileExp array
compileReduce _ _ = error "reduce needs 3 arguments" 
-- compileReduce for arrays

compileKernel :: T.Exp -> F.Type -> Kernel
compileKernel (T.Var ident) rtp = makeKernel ident
compileKernel (T.Fn ident tp (T.Fn ident2 tp2 exp)) rtp = F.Fn rtp [(compileTp tp,ident),(compileTp tp2,ident2)] (compileExp exp)
compileKernel (T.Fn ident tp exp) rtp = F.Fn rtp [(compileTp tp,ident)] (compileExp exp)

makeKernel ident
  | Just fun <- convertFun ident = F.Fun fun []
  | Just op  <- convertBinOp ident = F.Op op
  | otherwise = error $ "not supported operation " ++ ident

compileTp (ArrT bt (R rank)) = makeArrTp (makeBTp bt) rank
compileTp (VecT bt (R rank)) = makeArrTp (makeBTp bt) 1
compileTp (SV bt (R rank)) = makeArrTp (makeBTp bt) 1
compileTp (S bt (R rank)) = makeBTp bt

makeBTp T.IntT = F.IntT
makeBTp T.DoubleT = F.RealT
makeBTp T.BoolT = F.BoolT
makeBTp T.CharT = F.CharT

makeArrTp :: F.Type -> Integer -> F.Type
makeArrTp btp 0 = btp
makeArrTp btp n = F.ArrayT (makeArrTp btp (n-1))
