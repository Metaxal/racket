#lang racket/base

;; Contract generation for Typed Racket

(require
 "../utils/utils.rkt"
 syntax/parse
 (rep type-rep filter-rep object-rep)
 (utils tc-utils)
 (env type-name-env)
 (rep rep-utils)
 (types resolve union)
 (prefix-in t: (types abbrev numeric-tower))
 (private parse-type syntax-properties)
 racket/match racket/syntax racket/list
 racket/format
 racket/dict
 unstable/list
 unstable/sequence
 (static-contracts instantiate optimize structures combinators)
 ;; TODO make this from contract-req
 (prefix-in c: racket/contract)
 (contract-req)
 (for-syntax racket/base syntax/parse racket/syntax)
 (for-template racket/base racket/contract (utils any-wrap)))

(provide
  (c:contract-out
    [type->static-contract
      (c:parametric->/c (a) ((Type/c (c:-> #:reason (c:or/c #f string?) a))
                             (#:typed-side boolean?) . c:->* . (c:or/c a static-contract?)))]))

(provide type->contract define/fixup-contract? change-contract-fixups
         type->contract-fail any-wrap/sc)

;; These check if either the define form or the body form has the syntax
;; property. Normally the define form will have the property but lifting an
;; expression to the module level will put the property on the body.
(define-syntax (contract-finders stx)
  (define-syntax-class clause
    (pattern name:id
      #:with external-name (format-id #'name "typechecker:~a" #'name)
      #:with syntax-class-name (format-id #'name "~a^" #'name)))
  (syntax-parse stx
    [(_ #:union union-name:id :clause ... )
     #'(begin
         (define external-name
           (syntax-parser
              #:literal-sets (kernel-literals)
              [(~or (~var v syntax-class-name)
                    (define-values (_) (~var v syntax-class-name)))
               (attribute v.value)]
              [_ #f])) ...
         (define (union-name stx)
           (or (external-name stx) ...)))]))

(contract-finders
  #:union define/fixup-contract?
  contract-def flat-contract-def contract-def/maker)

;; type->contract-fail : Syntax Type #:ctc-str String
;;                       -> #:reason (Option String) -> Void
;; Curried function that produces a function to report
;; type->contract failures
(define ((type->contract-fail to-check to-report
                              #:ctc-str [ctc-str "contract"])
         #:reason [reason #f])
  (tc-error/stx
   to-report
   (~a "Type ~a could not be converted to a "
       ctc-str
       (if reason (~a ": " reason) "."))
   to-check))

(define (generate-contract-def stx)
  (define prop (define/fixup-contract? stx))
  (define maker? (typechecker:contract-def/maker stx))
  (define flat? (typechecker:flat-contract-def stx))
  (define typ (parse-type prop))
  (define kind (if flat? 'flat 'impersonator))
  (syntax-parse stx #:literals (define-values)
    [(define-values (n) _)
     (let ([typ (if maker?
                    ((map fld-t (Struct-flds (lookup-type-name (Name-id typ)))) #f . t:->* . typ)
                    typ)])
         (with-syntax ([cnt (type->contract
                             typ
                             ;; this is for a `require/typed', so the value is not from the typed side
                             #:typed-side #f
                             #:kind kind
                             (type->contract-fail typ prop))])
           (ignore ; should be ignored by the optimizer
            (quasisyntax/loc
                stx
              (define-values (n)
                (recursive-contract
                 cnt
                 #,(contract-kind->keyword kind)))))))]
    [_ (int-err "should never happen - not a define-values: ~a"
                (syntax->datum stx))]))

(define (change-contract-fixups forms)
  (for/list ((e (in-syntax forms)))
    (if (not (define/fixup-contract? e))
        e
        (generate-contract-def e))))

;; To avoid misspellings
(define impersonator-sym 'impersonator)
(define chaperone-sym 'chaperone)
(define flat-sym 'flat)

(define (contract-kind-max i . args)
  (define (contract-kind-max2 x y)
    (cond
      ((equal? flat-sym x) y)
      ((equal? flat-sym y) x)
      ((equal? chaperone-sym x) y)
      ((equal? chaperone-sym y) x)
      (else impersonator-sym)))
  (for/fold ((acc i)) ((v (in-list args)))
    (contract-kind-max2 v acc)))

(define (contract-kind-min i . args)
  (define (contract-kind-min2 x y)
    (cond
      ((equal? flat-sym x) x)
      ((equal? flat-sym y) y)
      ((equal? chaperone-sym x) x)
      ((equal? chaperone-sym y) y)
      (else impersonator-sym)))
  (for/fold ((acc i)) ((v (in-list args)))
    (contract-kind-min2 v acc)))


(define (contract-kind->keyword sym)
  (string->keyword (symbol->string sym)))

(define (from-typed? side)
  (case side
   [(typed both) #t]
   [(untyped) #f]))

(define (from-untyped? side)
  (case side
   [(untyped both) #t]
   [(typed) #f]))

(define (flip-side side)
  (case side
   [(typed) 'untyped]
   [(untyped) 'typed]
   [(both) 'both]))

(define (type->contract ty init-fail #:typed-side [typed-side #t] #:kind [kind 'impersonator])
  (let/ec escape
    (define (fail #:reason [reason #f]) (escape (init-fail #:reason reason)))
    (instantiate
      (optimize
        (type->static-contract ty #:typed-side typed-side fail)
        #:trusted-positive typed-side
        #:trusted-negative (not typed-side))
      fail
      kind)))




(define any-wrap/sc (chaperone/sc #'any-wrap/c))

(define (no-duplicates l)
  (= (length l) (length (remove-duplicates l))))

(struct triple (untyped typed both))
(define (triple-lookup trip side)
  (case side
    ((untyped) (triple-untyped trip))
    ((typed) (triple-typed trip))
    ((both) (triple-both trip))))
(define (same sc)
  (triple sc sc sc))


(define (type->static-contract type init-fail #:typed-side [typed-side #t])
  (let/ec return
    (define (fail #:reason reason) (return (init-fail #:reason reason)))
    (let loop ([type type] [typed-side (if typed-side 'typed 'untyped)] [recursive-values (hash)])
      (define (t->sc t #:recursive-values (recursive-values recursive-values))
        (loop t typed-side recursive-values))
      (define (t->sc/neg t #:recursive-values (recursive-values recursive-values))
        (loop t (flip-side typed-side) recursive-values))
      (define (t->sc/both t #:recursive-values (recursive-values recursive-values))
        (loop t 'both recursive-values))
      (define (t->sc/method t) (t->sc/function t fail typed-side recursive-values loop #t))
      (define (t->sc/fun t) (t->sc/function t fail typed-side recursive-values loop #f))
      (match type
        [(or (App: _ _ _) (Name: _)) (t->sc (resolve-once type))]
        [(Univ:) (if (from-typed? typed-side) any-wrap/sc any/sc)]
        [(Mu: var (Union: (list (Value: '()) (Pair: elem-ty (F: var)))))
         (listof/sc (t->sc elem-ty))]
        [(Base: sym cnt _ _)
         (flat/sc #`(flat-named-contract '#,sym (flat-contract-predicate #,cnt)) sym)]
        [(Refinement: par p?)
         (and/sc (t->sc par) (flat/sc p?))]
        [(Union: elems)
         (define-values (numeric non-numeric) (partition (λ (t) (equal? 'number (Type-key t))) elems ))
         (define numeric-sc (numeric-type->static-contract (apply Un numeric)))
         (if numeric-sc
             (apply or/sc numeric-sc (map t->sc non-numeric))
             (apply or/sc (map t->sc elems)))]
        [(and t (Function: _)) (t->sc/fun t)]
        [(Set: t) (set/sc (t->sc t))]
        [(Sequence: ts) (apply sequence/sc (map t->sc ts))]
        [(Vector: t) (vectorof/sc (t->sc/both t))]
        [(HeterogeneousVector: ts) (apply vector/sc (map t->sc/both ts))]
        [(Box: t) (box/sc (t->sc/both t))]
        [(Pair: t1 t2)
         (cons/sc (t->sc t1) (t->sc t2))]
        [(Promise: t)
         (promise/sc (t->sc t))]
        [(Opaque: p?)
         (flat/sc #`(flat-named-contract (quote #,(syntax-e p?)) #,p?))]
        [(Continuation-Mark-Keyof: t)
         (continuation-mark-key/sc (t->sc t))]
        ;; TODO: this is not quite right for case->
        [(Prompt-Tagof: s (Function: (list (arr: (list ts ...) _ _ _ _))))
         (prompt-tag/sc (map t->sc ts) (t->sc s))]
        ;; TODO
        [(F: v)
         (triple-lookup
           (hash-ref recursive-values v
             (λ () (error 'type->static-contract
                          "Recursive value lookup failed. ~a ~a" recursive-values v)))
           typed-side)]
        [(Poly: vs b)
         (if (not (from-untyped? typed-side))
             ;; in positive position, no checking needed for the variables
             (let ((recursive-values (for/fold ([rv recursive-values]) ([v vs])
                                       (hash-set rv v (same any/sc)))))
               (t->sc b #:recursive-values recursive-values))
             ;; in negative position, use parameteric contracts.
             (match-let ([(Poly-names: vs-nm b) type])
               (define function-type?
                 (let loop ([ty b])
                   (match (resolve ty)
                     [(Function: _) #t]
                     [(Union: elems) (andmap loop elems)]
                     [(Poly: _ body) (loop body)]
                     [(PolyDots: _ body) (loop body)]
                     [_ #f])))
               (unless function-type?
                 (fail #:reason "cannot generate contract for non-function polymorphic type"))
               (let ((temporaries (generate-temporaries vs-nm)))
                 (define rv (for/fold ((rv recursive-values)) ((temp temporaries)
                                                               (v-nm vs-nm))
                              (hash-set rv v-nm (same (parametric-var/sc temp)))))
                 (parametric->/sc temporaries
                    (t->sc b #:recursive-values rv)))))]
        [(PolyDots: (list vs ... dotted-v) b)
         (if (not (from-untyped? typed-side))
             ;; in positive position, no checking needed for the variables
             (let ((recursive-values (for/fold ([rv recursive-values]) ([v vs])
                                       (hash-set rv v (same any/sc)))))
               (t->sc b #:recursive-values recursive-values))
             ;; in negative position, use parameteric contracts.
             (fail #:reason "cannot generate contract for variable arity polymorphic type"))]

        [(Mu: n b)
         (match-define (and n*s (list untyped-n* typed-n* both-n*)) (generate-temporaries (list n n n)))
         (define rv
           (hash-set recursive-values n
                     (triple (recursive-sc-use untyped-n*)
                             (recursive-sc-use typed-n*)
                             (recursive-sc-use both-n*))))
         (case typed-side
           [(both) (recursive-sc
                     (list both-n*)
                     (list (loop b 'both rv))
                     (recursive-sc-use both-n*))]
           [(typed untyped)
            ;; TODO not fail in cases that don't get used
            (define untyped (loop b 'untyped rv))
            (define typed (loop b 'typed rv))
            (define both (loop b 'both rv))
  
            (recursive-sc
                     n*s
                     (list untyped typed both)
                     (recursive-sc-use (if (from-typed? typed-side) typed-n* untyped-n*)))])]
        [(Instance: (? Mu? t))
         (t->sc (make-Instance (resolve-once t)))]
        [(Instance: (Class: _ _ (list (list names functions) ...)))
         (object/sc (map (λ (n sc) (member-spec 'method n sc)) names (map t->sc/method functions)))]
        [(Class: _ (list (list by-name-inits by-name-init-tys _) ...) (list (list names functions) ...))
         (class/sc (append
                     (map (λ (n sc) (member-spec 'method n sc))
                          names (map t->sc/method functions))
                     (map (λ (n sc) (member-spec 'init n sc))
                          by-name-inits (map t->sc/neg by-name-init-tys)))
                   #f empty empty)]
        [(Struct: nm par (list (fld: flds acc-ids mut?) ...) proc poly? pred?)
         (cond
           [(dict-ref recursive-values nm #f)]
           [proc (fail #:reason "procedural structs are not supported")]
           [poly?
            (define nm* (generate-temporary #'n*))
            (define fields
              (for/list ([fty flds] [mut? mut?])
                (t->sc fty #:recursive-values (hash-set
                                                recursive-values
                                                nm (recursive-sc-use nm*)))))
            (recursive-sc (list nm*) (list (struct/sc nm (ormap values mut?) fields))
                                (recursive-sc-use nm*))]
           [else (flat/sc #`(flat-named-contract '#,(syntax-e pred?) #,pred?))])]
        [(Syntax: (Base: 'Symbol _ _ _)) identifier?/sc]
        [(Syntax: t)
         (syntax/sc (t->sc t))]
        [(Value: v)
         (flat/sc #`(flat-named-contract '#,v (lambda (x) (equal? x '#,v))) v)]
        [(Param: in out) 
         (parameter/sc (t->sc in) (t->sc out))]
        [(Hashtable: k v)
         (hash/sc (t->sc k) (t->sc v))]
        [(Channel: t)
         (channel/sc (t->sc t))]
        [else
         (fail #:reason "contract generation not supported for this type")]))))

(define (t->sc/function f fail typed-side recursive-values loop method?)
  (define (t->sc t #:recursive-values (recursive-values recursive-values))
    (loop t typed-side recursive-values))
  (define (t->sc/neg t #:recursive-values (recursive-values recursive-values))
    (loop t (flip-side typed-side) recursive-values))
  (match f
    [(Function: (list (top-arr:))) (case->/sc empty)]
    [(Function: arrs)
     ;; Try to generate a single `->*' contract if possible.
     ;; This allows contracts to be generated for functions with both optional and keyword args.
     ;; (and don't otherwise require full `case->')
     (define conv (match-lambda [(Keyword: kw kty _) (list kw (t->sc/neg kty))]))
     (define (partition-kws kws) (partition (match-lambda [(Keyword: _ _ mand?) mand?]) kws))
     (define (process-dom dom*)  (if method? (cons any/sc dom*) dom*))
     (cond
      ;; To generate a single `->*', everything must be the same for all arrs, except for positional
      ;; arguments which can increase by at most one each time.
      ;; Note: optional arguments can only increase by 1 each time, to avoid problems with
      ;;  functions that take, e.g., either 2 or 6 arguments. These functions shouldn't match,
      ;;  since this code would generate contracts that accept any number of arguments between
      ;;  2 and 6, which is wrong.
      ;; TODO sufficient condition, but may not be necessary
      [(and
        (> (length arrs) 1)
        ;; Keyword args, range and rest specs all the same.
        (let* ([xs (map (match-lambda [(arr: _ rng rest-spec _ kws)
                                       (list rng rest-spec kws)])
                        arrs)]
               [first-x (first xs)])
          (for/and ([x (in-list (rest xs))])
            (equal? x first-x)))
        ;; Positionals are monotonically increasing by at most one.
        (let-values ([(_ ok?)
                      (for/fold ([positionals (arr-dom (first arrs))]
                                 [ok-so-far?  #t])
                          ([arr (in-list (rest arrs))])
                        (match arr
                          [(arr: dom _ _ _ _)
                           (define ldom         (length dom))
                           (define lpositionals (length positionals))
                           (values dom
                                   (and ok-so-far?
                                        (or (= ldom lpositionals)
                                            (= ldom (add1 lpositionals)))
                                        (equal? positionals (take dom lpositionals))))]))])
          ok?))
       (match* ((first arrs) (last arrs))
         [((arr: first-dom (Values: (list (Result: rngs (FilterSet: (Top:) (Top:)) (Empty:)) ...)) rst #f kws)
           (arr: last-dom _ _ _ _)) ; all but dom is the same for all
          (define mand-args (map t->sc/neg first-dom))
          (define opt-args (map t->sc/neg (drop last-dom (length first-dom))))
          (define-values (mand-kws opt-kws)
            (let*-values ([(mand-kws opt-kws) (partition-kws kws)])
              (values (map conv mand-kws)
                      (map conv opt-kws))))
          (define range (map t->sc rngs))
          (define rest (and rst (listof/sc (t->sc/neg rst))))
          (function/sc (process-dom mand-args) opt-args mand-kws opt-kws rest range)])]
      [else
       (define ((f case->) a)
         (define (convert-arr arr)
           (match arr
             [(arr: dom (Values: (list (Result: rngs _ _) ...)) rst drst kws)
              (let-values ([(mand-kws opt-kws) (partition-kws kws)])
                ;; Garr, I hate case->!
                (when (and (not (empty? kws)) case->)
                  (fail #:reason (~a "cannot generate contract for case function type"
                                     " with optional keyword arguments")))
                (if case->
                  (arr/sc (map t->sc/neg dom) (and rst (t->sc/neg rst)) (map t->sc rngs))
                  (function/sc
                    (process-dom (map t->sc/neg dom))
                    null
                    (map conv mand-kws)
                    (map conv opt-kws)
                    (or
                      (and rst (listof/sc (t->sc/neg rst)))
                      (and drst (listof/sc (t->sc/neg (car drst)
                                                      #:recursive-values
                                                        (hash-set recursive-values (cdr drst) (same any/sc))))))
                    (map t->sc rngs))))]))
         (match a
           ;; functions with no filters or objects
           [(arr: dom (Values: (list (Result: rngs (FilterSet: (Top:) (Top:)) (Empty:)) ...)) rst drst kws)
            (convert-arr a)]
           ;; functions with filters or objects
           [(arr: dom (Values: (list (Result: rngs _ _) ...)) rst drst kws)
            (if (from-untyped? typed-side)
                (fail #:reason (~a "cannot generate contract for function type"
                                   " with filters or objects."))
                (convert-arr a))]))
       (define arities
         (for/list ([t arrs])
           (match t
             [(arr: dom _ _ _ _) (length dom)]
             ;; is there something more sensible here?
             [(top-arr:) (int-err "got top-arr")])))
       (define maybe-dup (check-duplicate arities))
       (when maybe-dup
         (fail #:reason (~a "function type has two cases of arity " maybe-dup)))
       (if (= (length arrs) 1)
           ((f #f) (first arrs))
           (case->/sc (map (f #t) arrs)))])]
    [_ (int-err "not a function" f)]))

(module predicates racket/base
  (provide nonnegative? nonpositive?)
  (define nonnegative? (lambda (x) (>= x 0)))
  (define nonpositive? (lambda (x) (<= x 0))))

(module numeric-contracts racket/base
  (require
    "../utils/utils.rkt"
    (static-contracts combinators)
    (for-template
      racket/base
      racket/contract
      (submod ".." predicates)
      (prefix-in t: (types numeric-predicates))))
  (provide (all-defined-out))

  (define-syntax-rule (numeric/sc name body)
    (flat/sc #'(flat-named-contract 'name body) 'name))

  (define positive-byte/sc (numeric/sc Positive-Byte (and/c byte? positive?)))
  (define byte/sc (numeric/sc Byte byte?))
  (define positive-index/sc (numeric/sc Positive-Index (and/c t:index? positive?)))
  (define index/sc (numeric/sc Index t:index?))
  (define positive-fixnum/sc (numeric/sc Positive-Fixnum (and/c fixnum? positive?)))
  (define nonnegative-fixnum/sc (numeric/sc Nonnegative-Fixnum (and/c fixnum? nonnegative?)))
  (define nonpositive-fixnum/sc (numeric/sc Nonpositive-Fixnum (and/c fixnum? nonpositive?)))
  (define fixnum/sc (numeric/sc Fixnum fixnum?))
  (define positive-integer/sc (numeric/sc Positive-Integer (and/c exact-integer? positive?)))
  (define natural/sc (numeric/sc Natural exact-nonnegative-integer?))
  (define negative-integer/sc (numeric/sc Negative-Integer (and/c exact-integer? negative?)))
  (define nonpositive-integer/sc (numeric/sc Nonpositive-Integer (and/c exact-integer? nonpostive?)))
  (define integer/sc (numeric/sc Integer exact-integer?))
  (define positive-rational/sc (numeric/sc Positive-Rational (and/c t:exact-rational? positive?)))
  (define nonnegative-rational/sc (numeric/sc Nonnegative-Rational (and/c t:exact-rational? nonnegative?)))
  (define negative-rational/sc (numeric/sc Negative-Rational (and/c t:exact-rational? negative?)))
  (define nonpositive-rational/sc (numeric/sc Nonpositive-Rational (and/c t:exact-rational? nonpositive?)))
  (define rational/sc (numeric/sc Rational t:exact-rational?))
  (define flonum-zero/sc (numeric/sc Float-Zero (and/c flonum? zero?)))
  (define nonnegative-flonum/sc (numeric/sc Nonnegative-Float (and/c flonum? nonnegative?)))
  (define nonpositive-flonum/sc (numeric/sc Nonpositive-Float (and/c flonum? nonpositive?)))
  (define flonum/sc (numeric/sc Float flonum?))
  (define single-flonum-zero/sc (numeric/sc Single-Flonum-Zero (and/c single-flonum? zero?)))
  (define inexact-real-zero/sc (numeric/sc Inexact-Real-Zero (and/c inexact-real? zero?)))
  (define positive-inexact-real/sc (numeric/sc Positive-Inexact-Real (and/c inexact-real? positive?)))
  (define nonnegative-single-flonum/sc (numeric/sc Nonnegative-Single-Flonum (and/c single-flonum? nonnegative?)))
  (define nonnegative-inexact-real/sc (numeric/sc Nonnegative-Inexact-Real (and/c inexact-real? nonpositive?)))
  (define negative-inexact-real/sc (numeric/sc Negative-Inexact-Real (and/c inexact-real? negative?)))
  (define nonpositive-single-flonum/sc (numeric/sc Nonpositive-Single-Flonum (and/c single-flonum? nonnegative?)))
  (define nonpositive-inexact-real/sc (numeric/sc Nonpositive-Inexact-Real (and/c inexact-real? nonpositive?)))
  (define single-flonum/sc (numeric/sc Single-Flonum single-flonum?))
  (define inexact-real/sc (numeric/sc Inexact-Real inexact-real?))
  (define real-zero/sc (numeric/sc Real-Zero (and/c real? zero?)))
  (define positive-real/sc (numeric/sc Positive-Real (and/c real? positive?)))
  (define nonnegative-real/sc (numeric/sc Nonnegative-Real (and/c real? nonnegative?)))
  (define negative-real/sc (numeric/sc Negative-Real (and/c real? negative?)))
  (define nonpositive-real/sc (numeric/sc Nonpositive-Real (and/c real? nonpositive?)))
  (define real/sc (numeric/sc Real real?))
  (define exact-number/sc (numeric/sc Exact-Number (and/c number? exact?)))
  (define inexact-complex/sc
    (numeric/sc Inexact-Complex
                 (and/c number?
                   (lambda (x)
                     (and (inexact-real? (imag-part x))
                          (inexact-real? (real-part x)))))))
  (define number/sc (numeric/sc Number number?))

  )
(require 'numeric-contracts)

(define (numeric-type->static-contract type)
  (match type
    ;; numeric special cases
    ;; since often-used types like Integer are big unions, this would
    ;; generate large contracts.
    [(== t:-PosByte type-equal?) positive-byte/sc]
    [(== t:-Byte type-equal?) byte/sc]
    [(== t:-PosIndex type-equal?) positive-index/sc]
    [(== t:-Index type-equal?) index/sc]
    [(== t:-PosFixnum type-equal?) positive-fixnum/sc]
    [(== t:-NonNegFixnum type-equal?) nonnegative-fixnum/sc]
    ;; -NegFixnum is a base type
    [(== t:-NonPosFixnum type-equal?) nonpositive-fixnum/sc]
    [(== t:-Fixnum type-equal?) fixnum/sc]
    [(== t:-PosInt type-equal?) positive-integer/sc]
    [(== t:-Nat type-equal?) natural/sc]
    [(== t:-NegInt type-equal?) negative-integer/sc]
    [(== t:-NonPosInt type-equal?) nonpositive-integer/sc]
    [(== t:-Int type-equal?) integer/sc]
    [(== t:-PosRat type-equal?) positive-rational/sc]
    [(== t:-NonNegRat type-equal?) nonnegative-rational/sc]
    [(== t:-NegRat type-equal?) negative-rational/sc]
    [(== t:-NonPosRat type-equal?) nonpositive-rational/sc]
    [(== t:-Rat type-equal?) rational/sc]
    [(== t:-FlonumZero type-equal?) flonum-zero/sc]
    [(== t:-NonNegFlonum type-equal?) nonnegative-flonum/sc]
    [(== t:-NonPosFlonum type-equal?) nonpositive-flonum/sc]
    [(== t:-Flonum type-equal?) flonum/sc]
    [(== t:-SingleFlonumZero type-equal?) single-flonum-zero/sc]
    [(== t:-InexactRealZero type-equal?) inexact-real-zero/sc]
    [(== t:-PosInexactReal type-equal?) positive-inexact-real/sc]
    [(== t:-NonNegSingleFlonum type-equal?) nonnegative-single-flonum/sc]
    [(== t:-NonNegInexactReal type-equal?) nonnegative-inexact-real/sc]
    [(== t:-NegInexactReal type-equal?) negative-inexact-real/sc]
    [(== t:-NonPosSingleFlonum type-equal?) nonpositive-single-flonum/sc]
    [(== t:-NonPosInexactReal type-equal?) nonpositive-inexact-real/sc]
    [(== t:-SingleFlonum type-equal?) single-flonum/sc]
    [(== t:-InexactReal type-equal?) inexact-real/sc]
    [(== t:-RealZero type-equal?) real-zero/sc]
    [(== t:-PosReal type-equal?) positive-real/sc]
    [(== t:-NonNegReal type-equal?) nonnegative-real/sc]
    [(== t:-NegReal type-equal?) negative-real/sc]
    [(== t:-NonPosReal type-equal?) nonpositive-real/sc]
    [(== t:-Real type-equal?) real/sc]
    [(== t:-ExactNumber type-equal?) exact-number/sc]
    [(== t:-InexactComplex type-equal?) inexact-complex/sc]
    [(== t:-Number type-equal?) number/sc]
    [else #f]))


