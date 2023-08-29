import Lean.Elab.Tactic.ElabTerm
import Lean.Elab.Tactic.Conv.Basic

import Std.Tactic.GuardMsgs

import SciLean.Lean.Meta.Basic
import SciLean.Lean.Expr

import SciLean.Util.RewriteBy

namespace SciLean.Meta

open Lean Meta Elab Tactic Conv

structure NormalizeLetConfig where
  removeTrivialLet := true
  removeNoFVarLet := false  
  removeLambdaLet  := true
  removeFVarProjLet := true
  splitStructureConstuctors := true
  reduceProjections := true


/-- Is `e` in the form `p₁ (...(pₙ x))` where `pᵢ` are projections and `x` free variable?
-/
def isProjectionOfFVar (e : Expr) : MetaM Bool := do
  match e with
  | .mdata _ e => isProjectionOfFVar e
  | .fvar _ => return true
  | .app f x => 
    if f.isProj then
      isProjectionOfFVar x
    else
      let some projName := f.getAppFn'.constName? | return false
      let some info ← getProjectionFnInfo? projName | return false
      if info.numParams = f.getAppNumArgs then
        isProjectionOfFVar x 
      else
        return false
  | _ => return false


/-- Normalizes let bindings in an expression 

Two main normalizations are:

1. nested let bindings`
```
let x :=
  let y := a + b
  f y
g x
==>
let y := a + b
let x := f y
g x
```

2. let bindings in application
```
(let x := 10; add x) (let y := 5; y + 1)
==>
let x := 10
let y := 5
add x (y + 1)
```

Additional optional normalizations:

remove trivial let
```
let y := x
y
==>
x
```

remove no fvar let
```
let x := 10
x
==>
10
```

remove lambda let
```
let f := fun x => x + x
f 1
==>
1 + 1
```

split structure constuctors
```
let z := (f x, g y)
z
==>
let z₁ := f x
let z₂ := g y
==>
(z₁, z₂)
```
-/
partial def normalizeLet (e : Expr) (config : NormalizeLetConfig := {}) : MetaM Expr := do
  match e.consumeMData.headBeta with
  | .letE xName xType xValue xBody _ => do
    match (← normalizeLet xValue config).consumeMData with
    | .letE yName yType yValue yBody _ => 
      withLetDecl yName yType yValue fun y => 
      withLetDecl xName xType (yBody.instantiate1 y) fun x => do
        mkLambdaFVars #[y,x] (xBody.instantiate1 x) >>= normalizeLet (config:=config)

    | xValue' => do
      if (xValue'.isFVar) && config.removeTrivialLet then
        return ← normalizeLet (xBody.instantiate1 xValue') config

      if ¬(xValue.hasAnyFVar (fun _ => true)) && config.removeNoFVarLet then
        return ← normalizeLet (xBody.instantiate1 xValue') config

      if xValue'.isLambda && config.removeLambdaLet then
        return ← normalizeLet (xBody.instantiate1 xValue') config

      if (← isProjectionOfFVar xValue') && config.removeFVarProjLet then
        return ← normalizeLet (xBody.instantiate1 xValue') config

      -- deconstruct constructors into bunch of let bindings
      if config.splitStructureConstuctors then
        if let .some (ctor, args) := xValue'.constructorApp? (← getEnv) then 
          if let .some info := getStructureInfo? (← getEnv) xType.getAppFn.constName! then
            let mut lctx ← getLCtx
            let insts ← getLocalInstances
            let mut fvars : Array Expr := #[]
            for i in [0:ctor.numFields] do
              let fvarId ← withLCtx lctx insts mkFreshFVarId
              let name := xName.appendAfter s!"_{info.fieldNames[i]!}"
              let val  := args[ctor.numParams + i]!
              let type ← inferType val
              lctx := lctx.mkLetDecl fvarId name type val (nonDep := false) default
              fvars := fvars.push (.fvar fvarId)

            let e' ← withLCtx lctx insts do
              let xValue'' := mkAppN xValue'.getAppFn (args[0:ctor.numFields].toArray.append fvars)
              mkLambdaFVars fvars (xBody.instantiate1 xValue'')

            return (← normalizeLet e' config)

      -- in all other cases normalized the body
      withLetDecl xName xType xValue' fun x => do
        mkLambdaFVars #[x] (← normalizeLet (xBody.instantiate1 x) config)

  | .app f x => do
    match (← normalizeLet f) with
    | .letE yName yType yValue yBody _ => 
      withLetDecl yName yType yValue fun y => do
      normalizeLet (← mkLambdaFVars #[y] (.app (yBody.instantiate1 y) x)) config
    | f' => 
      match (← normalizeLet x) with
      | .letE yName yType yValue yBody _ => 
        withLetDecl yName yType yValue fun y => do
        normalizeLet (← mkLambdaFVars #[y] (.app f' (yBody.instantiate1 y))) config
      | x' => do
        if config.reduceProjections then
          if let .some e' ← reduceProjFn?' (f'.app x') then
            return e'

        return (f'.app x')

  | .lam xName xType xBody xBi => 
    withLocalDecl xName xBi xType fun x => do
      mkLambdaFVars #[x] (← normalizeLet (xBody.instantiate1 x) config)

  | e => pure e

syntax (name := let_normalize) "let_normalize" : conv 

@[tactic let_normalize] 
def convLetNormalize : Tactic
| `(conv| let_normalize) =>   
  withTraceNode `let_normalize (fun _ => return "let_normalize") do
  (← getMainGoal).withContext do
    let lhs ← getLhs
    let lhs' ← normalizeLet lhs
    
    changeLhs lhs'
| _ => Lean.Elab.throwUnsupportedSyntax

macro "let_normalize" : tactic => `(tactic| conv => let_normalize)



/--
info: let x1 := 10;
let x2 := x1 + 5;
let h2 := 2;
let h1 := h2 + 1;
let y1 := 4;
let y2 := 5;
let y3 := 14;
let fy2 := 4;
let fy3 := h1 + h1;
let y4 := 56;
let y5 := y1 + y3 + (h1 + 100 + fy2 + fy3) + (y2 + y4);
let z1 := 1;
let z2 := 2;
let z3_fst := z1 + z1;
let z3_snd := z2 * z2;
x2 + y5 + z3_fst + z3_snd : Nat
-/
#guard_msgs in
#check 
    (let x3 :=
      let x2 := 
        let x1 := 10
        x1 + 5
      x2
    let h1 := 
      let h2 := 2
      h2 + 1
    let y5 := 
      let y1 := 4
      let y2 := 5
      (let y3 := 14; let f1 := fun x => let fy1 := let fy2 := 4; fy2; let fy3 := x + x; x + 100 + fy1 + fy3; y1 + y3 + f1 h1) + (let y4 := 56; y2 + y4)
    let z3 :=
      (let z1 := 1; z1 + z1, let z2 := 2; z2 * z2)
    x3 + y5 + z3.1 + z3.2)
    rewrite_by
      let_normalize

