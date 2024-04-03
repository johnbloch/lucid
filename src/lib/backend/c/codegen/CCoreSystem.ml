(* CCore system function implementations (time, random, and hasn)  *)
open CCoreSyntax
open CCoreExceptions
open CCoreUtils
open Str

(* for now, group type is an alias for port type *)
let new_group_ty = tint ((!CCoreConfig.cfg).port_id_size) ;;
let group_ty_replacer ty = 
  if (is_tbuiltin tgroup_cid ty) then
    new_group_ty
  else ty
;;

(* Sys.time *)
let sys_time = 
  dfun_foriegn
    System.sys_time_cid
    (tint 32)
    []
    "{ return 0;// TODO! }"

(* Flood was a core builtin, now a Sys function *)
let sys_flood = 
  dfun_foriegn
    (cid"flood")
    (new_group_ty)
    [id"port", new_group_ty]
    "{ return port + 10000;// TODO! }"
;;
(* let flood_call_replacer exp = 
  if (is_ecall_cid exp (cid"flood")) then (
    let _, args = extract_ecall exp in 
    let flood_ty = tfun [new_group_ty] new_group_ty in
    ecall (efunref (cid"sys_flood") flood_ty) args
  )
  else exp
;; *)


(* LEFT OFF HERE
    hash uncovers a larger problem. 
    For tables, we may have compound keys. 
    But we're generating code that checks equality 
    assuming that we only have integer keys, basically. 
    Not even a _LIST_ of integer keys... 
    We need to handle more complex key and hash arg types. 
    Maybe some sort of flattening method? 
    This is actually a very performance sensitive thing. 
    So we need to proceed carefully...

*)

(*  

  int foo = hash<int>(a, b, c, d, ...); 
  // the arguments to hash may be any type. 
  // for each call to hash we want to do something 
  // simple, like interpret the arguments as a 
  // string of ints, add them and then do a mod operation.

uint32_t sys_hash(foo_struct foo, bar_struct bar) {
    uint32_t rv = 0;
    uint8_t* foo_bytes = (uint8_t* )&foo;
    uint8_t* bar_bytes = (uint8_t* )&bar;

    for (size_t i = 0; i < sizeof(foo); i++) {
        rv += foo_bytes[i];
    }

    for (size_t i = 0; i < sizeof(bar); i++) {
        rv += bar_bytes[i];
    }

    return rv;
}


*)
(* 
(* vector of ops *)
let rec eops op exps = 
  match exps with 
  | [] -> err "no expressions"
  | [exp] -> exp
  | exp::exps -> 
    eop op [exp; eops op exps]
;;
let hash_uid = ref 0;;
let mk_sys_hash size (args : exp list) = 
  hash_uid := !hash_uid + 1;
  dfun
    (cid@@"hash_"^(string_of_int (!hash_uid)))
    (tint size)
    (List.map extract_evar_id args)
    (sret)
    


;; *)

let process decls = 
  sys_time::sys_flood:: (*add the functions, replace group types with port types *)
  ( decls 
    |> CCoreTransformers.subst_ty#visit_decls group_ty_replacer
    (* |> CCoreTransformers.subst_exp#visit_decls flood_call_replacer *)
  )
