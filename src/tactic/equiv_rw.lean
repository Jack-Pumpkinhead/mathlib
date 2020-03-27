/-
Copyright (c) 2019 Scott Morrison. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Scott Morrison
-/
import category.equiv_functor

/-!
# The `equiv_rw` tactic transports goals or hypotheses along equivalences.

The basic syntax is `equiv_rw e`, where `e : α ≃ β` is an equivalence.
This will try to replace occurrences of `α` in the goal with `β`, for example
transforming
* `⊢ α` with `⊢ β`,
* `⊢ option α` with `⊢ option β`
* `⊢ {a // P}` with `{b // P (⇑(equiv.symm e) b)}`

The tactic can also be used to rewrite hypotheses, using the syntax `equiv_rw e at h`.

## Implementation details

The main internal function is `adapt_equiv t e`,
which attempts to turn an expression `e : α ≃ β` into a new equivalence with left hand side `t`.
As an example, with `t = option α`, it will generate `functor.map_equiv option e`.

This is achieved by generating a new synthetic goal `%%t ≃ _`,
and calling `solve_by_elim` with an appropriate set of congruence lemmas.
To avoid having to specify the relevant congruence lemmas by hand,
we mostly rely on `equiv_functor.map_equiv` and `bifunctor.map_equiv`
along with some structural congruence lemmas such as
* `equiv.arrow_congr'`,
* `equiv.subtype_equiv_of_subtype'`,
* `equiv.sigma_congr_left'`, and
* `equiv.Pi_congr_left'`.

The main `equiv_rw` function, when operating on the goal, simply generates a new equivalence `e'`
with left hand side matching the target, and calls `apply e'.inv_fun`.

When operating on a hypothesis `x : α`, we introduce a new fact `h : x = e.symm (e x)`,
revert this, and then attempt to `generalize`, replacing all occurrences of `e x` with a new constant `y`,
before `intro`ing and `subst`ing `h`, and renaming `y` back to `x`.

## Future improvements
In a future PR I anticipate that `derive equiv_functor` should work on many examples,
(internally using `transport`, which is in turn based on `equiv_rw`)
and we can incrementally bootstrap the strength of `equiv_rw`.

An ambitious project might be to add `equiv_rw!`,
a tactic which, when failing to find appropriate `equiv_functor` instances,
attempts to `derive` them on the spot.

For now `equiv_rw` is entirely based on `equiv` in `Type`,
but the framework can readily be generalised to also work with other types of equivalences,
for example specific notations such as ring equivalence (`≃+*`),
or general categorical isomorphisms (`≅`).

This will allow us to transport across more general types of equivalences,
but this will wait for another subsequent PR.
-/

namespace tactic

/-- A list of lemmas used for constructing congruence equivalences. -/

-- Although this looks 'hard-coded', in fact the lemma `equiv_functor.map_equiv`
-- allows us to extend `equiv_rw` simply by constructing new instance so `equiv_functor`.

-- TODO: We should also use `category_theory.functorial` and `category_theory.hygienic` instances.
-- (example goal: we could rewrite along an isomorphism of rings (either as `R ≅ S` or `R ≃+* S`)
-- and turn an `x : mv_polynomial σ R` into an `x : mv_polynomial σ S`.).

meta def equiv_congr_lemmas : tactic (list expr) :=
do exprs ←
  [
  `equiv.of_iff,
  -- TODO decide what to do with this; it's an equiv_bifunctor?
  `equiv.equiv_congr,
  -- The function arrow is technically a bifunctor `Typeᵒᵖ → Type → Type`,
  -- but the pattern matcher will never see this.
  `equiv.arrow_congr',
  -- Allow rewriting in subtypes:
  `equiv.subtype_equiv_of_subtype',
  -- Allow rewriting in the first component of a sigma-type:
  `equiv.sigma_congr_left',
  -- Allow rewriting ∀s:
  -- (You might think that repeated application of `equiv.forall_congr'
  -- would handle the higher arity cases, but unfortunately unification is not clever enough.)
  `equiv.forall₃_congr',
  `equiv.forall₂_congr',
  `equiv.forall_congr',
  -- Allow rewriting in argument of Pi types:
   `equiv.Pi_congr_left',
  -- Handles `sum` and `prod`, and many others:
  `bifunctor.map_equiv,
  -- Handles `list`, `option`, `unique`, and many others:
  `equiv_functor.map_equiv,
  -- We have to filter results to ensure we don't cheat and use exclusively `equiv.refl` and `iff.refl`!
  `equiv.refl,
  `iff.refl
  ].mmap (λ n, try_core (mk_const n)),
  return (exprs.map option.to_list).join -- TODO: implement `.mfilter_map mk_const`?

declare_trace adapt_equiv

/-- Implementation of `adapt_equiv`, using `solve_by_elim`. -/
meta def adapt_equiv_core (eq ty : expr) : tactic expr :=
do
  -- We prepare a synthetic goal of type `(%%ty ≃ _)`, for some placeholder right hand side.
  initial_goals ← get_goals,
  g ← to_expr ``(%%ty ≃ _) >>= mk_meta_var,
  set_goals [g],
  -- Assemble the relevant lemmas.
  equiv_congr_lemmas ← equiv_congr_lemmas,
  /-
    We now call `solve_by_elim` to try to generate the requested equivalence.
    There are a few subtleties!
    * We make sure that `eq` is the first lemma, so it is applied whenever possible.
    * In `equiv_congr_lemmas`, we put `equiv.refl` last so it is only used when it is not possible
      to descend further.
    * To avoid the possibility that the entire resulting expression is built out of
      congruence lemmas and `equiv.refl`, we use the `accept` subtactic of `solve_by_elim`
      to reject any results which neither contain `eq` or a remaining metavariable.
    * Since some congruence lemmas generate subgoals with `∀` statements,
      we use the `pre_apply` subtactic of `solve_by_elim` to preprocess each new goal with `intros`.
  -/
  solve_by_elim {
    use_symmetry := false,
    use_exfalso := false,
    lemmas := some (eq :: equiv_congr_lemmas),
    -- TODO decide an appropriate upper bound on search depth.
    max_steps := 6,
    -- Subgoals may contain function types,
    -- and we want to continue trying to construct equivalences after the binders.
    pre_apply := tactic.intros >> skip,
    discharger := trace_if_enabled `adapt_equiv "Failed, no congruence lemma applied!" >> failed,
    -- We accept any branch of the `solve_by_elim` search tree which
    -- either still contains metavariables, or already contains at least one copy of `eq`.
    -- This is to prevent generating equivalences built entirely out of `equiv.refl`.
    accept := λ goals, lock_tactic_state (do
      when_tracing `adapt_equiv (do
        goals.mmap pp >>= λ goals, trace format!"So far, we've built: {goals}"),
      goals.any_of (λ g, guard $ g.contains_expr_or_mvar eq) <|>
        (trace_if_enabled `adapt_equiv format!"Rejected, result does not contain {eq}" >> failed),
      done <|>
      when_tracing `adapt_equiv (do
        gs ← get_goals,
        gs ← gs.mmap (λ g, infer_type g >>= pp),
        trace format!"Attempting to adapt to {gs}"))
  },
  set_goals initial_goals,
  return g


/--
`adapt_equiv t e` "adapts" the equivalence `e`, producing a new equivalence with left-hand-side `t`.
-/
meta def adapt_equiv (ty : expr) (eq : expr) : tactic expr :=
do
  when_tracing `adapt_equiv (do
    ty_pp ← pp ty,
    eq_pp ← pp eq,
    eq_ty_pp ← infer_type eq >>= pp,
    trace format!"Attempting to adapt `{eq_pp} : {eq_ty_pp}` to produce `{ty_pp} ≃ _`."),
  `(_ ≃ _) ← infer_type eq | fail format!"{eq} must be an `equiv`",
  adapt_equiv_core eq ty

/--
Attempt to replace the hypothesis with name `x`
by transporting it along the equivalence in `e : α ≃ β`.
-/
meta def equiv_rw_hyp : Π (x : name) (e : expr), tactic unit
| x e :=
do
  x' ← get_local x,
  x_ty ← infer_type x',
  -- Adapt `e` to an equivalence with left-hand-sidee `x_ty`
  e ← adapt_equiv x_ty e,
  eq ← to_expr ``(%%x' = equiv.symm %%e (equiv.to_fun %%e %%x')),
  prf ← to_expr ``((equiv.symm_apply_apply %%e %%x').symm),
  h ← assertv_fresh eq prf,
  -- Revert the new hypothesis, so it is also part of the goal.
  revert h,
  ex ← to_expr ``(equiv.to_fun %%e %%x'),
  -- Now call `generalize`,
  -- attempting to replace all occurrences of `e x`,
  -- calling it for now `j : β`, with `k : x = e.symm j`.
  generalize ex (by apply_opt_param) transparency.none,
  -- Reintroduce `x` (now of type `b`).
  intro x,
  k ← mk_fresh_name,
  -- Finally, we subst along `k`, hopefully removing all the occurrences of the original `x`,
  intro k >>= (λ k, subst k <|> unfreeze_local_instances >> subst k),
  `[try { simp only [equiv.symm_symm, equiv.apply_symm_apply, equiv.symm_apply_apply] }],
  skip

/-- Rewrite the goal using an equiv `e`. -/
meta def equiv_rw_target (e : expr) : tactic unit :=
do
  t ← target,
  e ← adapt_equiv t e,
  s ← to_expr ``(equiv.inv_fun %%e),
  tactic.eapply s,
  skip

end tactic


namespace tactic.interactive
open lean.parser
open interactive interactive.types
open tactic

local postfix `?`:9001 := optional

/--
`equiv_rw e at h`, where `h : α` is a hypothesis, and `e : α ≃ β`,
will attempt to transport `h` along `e`, producing a new hypothesis `h : β`,
with all occurrences of `h` in other hypotheses and the goal replaced with `e.symm h`.

`equiv_rw e` will attempt to transport the goal along an equivalence `e : α ≃ β`.
In its minimal form it replaces the goal `⊢ α` with `⊢ β` by calling `apply e.inv_fun`.

`equiv_rw` will also try rewriting under (equiv-)functors, so can turn
a hypothesis `h : list α` into `h : list β` or
a goal `⊢ unique α` into `⊢ unique β`.
-/
meta def equiv_rw (e : parse texpr) (loc : parse $ (tk "at" *> ident)?) : itactic :=
do e ← to_expr e,
   match loc with
   | (some hyp) := tactic.equiv_rw_hyp hyp e
   | none := tactic.equiv_rw_target e
   end

add_tactic_doc
{ name        := "equiv_rw",
  category    := doc_category.tactic,
  decl_names  := [`tactic.interactive.equiv_rw],
  tags        := ["rewriting", "equiv", "transport"] }

end tactic.interactive
