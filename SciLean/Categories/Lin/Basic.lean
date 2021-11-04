import SciLean.Algebra
-- import SciLean.Categories.Basic

namespace SciLean

class IsLin {U V} [Vec U] [Vec V] (f : U → V) : Prop :=
  ( add : ∀ x y, f (x + y) = f x + f y )
  ( mul : ∀ (s : ℝ) x, f (s*x) = s * (f x) )

-- instance {X Y} [Vec X] [Vec Y] (f : X → Y) [IsLin f] : FetchProof IsLin f := by constructor; assumption

def LinMap (X Y : Type) [Vec X] [Vec Y] := { f : X → Y // IsLin f }

