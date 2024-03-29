(* deparser implementation *)
(* 

Assumptions:
  - the buffer is set up properly (cur points to start, buffer is large enough)
  - event parameters are efficiently packable (no padding)

deparse_event function:
  - for background events, start by serializing 
    an empty ethernet header and the event's tag
  - then, copy the event's params struct to the 
    output buffer. Note that the union is _NOT_ copied, 
    only the struct for the particular event. 

example:
program with an event 
  do_add(int i, int j, int k);
==>
fn int deparse_event(event* ev_out, bytes_t* buf_out){
  if (ev_out->is_packet == 0) {
    ((int* )(buf_out->cur))[0] = 0;
  ((int* )(buf_out->cur))[1] = 0;
  ((int* )(buf_out->cur))[2] = 0;
  ((int16* )(buf_out->cur + 12))[0] = 0;
  buf_out->cur = buf_out->cur + 14;
  (*(((event_tag_t*)(buf_out->cur)))) = ev_out->tag;
  buf_out->cur = buf_out->cur + 2;
} else {
  skip;
}
match (ev_out->tag) {
  case do_add_tag: {
    (*(((do_add_t*)(buf_out->cur)))) = ev_out->data.do_add;
    buf_out->cur = buf_out->cur + 12;
  }
}
return (buf_out->cur) - (buf_out->start);
}

TODO: 
  - support payloads
  - in-place deparsing vs packet copying
*)
open CCoreSyntax
open CCoreExceptions
let bytes_t = CCoreParse.bytes_t


(*  macros *)
let memcpy dst_ref_exp src_exp = 
  sassign_exp 
    (ederef (ecast (tref src_exp.ety) dst_ref_exp))
    src_exp
;;
let memset dst_ref_exp src_val = 
  sassign_exp 
    (ederef (ecast (tref src_val.vty) dst_ref_exp))
    (eval src_val)
;;
(* let memset_word dst_ref_exp src_val = 
  ((ecast (tref src_val.vty) dst_ref_exp))
;; *)
let memset_n dst_ref_exp src_val n = 
  stmts 
    (List.init n
      (fun i -> 
        let idx_exp = eval@@vint i 32 in
        ((ecast (tref src_val.vty) dst_ref_exp), idx_exp)/<-(eval src_val)))
;;
let ptr_incr eptr i = (eptr/+(eval@@vint i 32))
let sptr_incr eptr i = sassign_exp eptr (ptr_incr eptr i)
;;



let deparse_fun event_t = 
  let tag_enum_ty = 
    extract_trecord_or_union (base_type event_t) |> snd
    |> List.hd (* event.tag *)
  in
  let data_union_ty = List.nth
    (extract_trecord_or_union (base_type event_t) |> snd) 
    1 (* event.data *)
  in
  (* print_endline ("tag_enum_ty: "^(CCorePPrint.ty_to_string ~use_abstract_name:true tag_enum_ty));
  print_endline ("data_union_ty: "^(CCorePPrint.ty_to_string data_union_ty)); *)
  let tag_cids = List.split (extract_tenum (base_type tag_enum_ty)) |> fst in
  let event_struct_tys = extract_trecord_or_union (base_type data_union_ty) |> snd in
  (* let tag_symbols = List.map (fun cid -> eval@@vsymbol cid tag_enum_ty) tag_cids in *)
  let ev_out_param = id"ev_out", tref event_t in
  let buf_out_param = id"buf_out", tref bytes_t in
  let ev_out = param_evar ev_out_param in
  let buf_out = param_evar buf_out_param in
  (* start function def *)
  let fun_id = id"deparse_event" in
  let params = [ev_out_param; buf_out_param] in
  let body = stmts [
    slocal (cid"bytes_written") (tint 32) (default_exp (tint 32));
    sif (eop Eq [(ev_out/->id"is_packet");(eval@@vint 0 8)])
      (* not a packet / raw event *)
      (stmts [
        (* set empty eth header *)
        memset_n (buf_out/->id"cur") (vint 0 32) 3; (* 12 bytes *)
        memset_n (ptr_incr (buf_out/->id"cur") 12) (vint 0 16) 1; (* 2 bytes *)
        sptr_incr (buf_out/->id"cur") 14;
        (* set event type *)
        memcpy (buf_out/->id"cur") (ev_out/->id"tag");
        sptr_incr (buf_out/->id"cur") 2;
        sassign 
          (cid"bytes_written") 
          ((evar (cid"bytes_written") (tint 32))/+(eval@@vint 16 32))
      ])
      (snoop);
    smatch [ev_out/->id"tag"] 
      (* one branch for each event *)
      (List.map2 
        (fun tag_cid event_struct_ty -> 
          let this_event_data_field = CCoreEvents.event_untag (Cid.to_id tag_cid) in
          [PVal(vsymbol tag_cid tag_enum_ty)],
          stmts [
            (* copy to memory *)
            memcpy (buf_out/->id"cur") ((ev_out/->id"data")/.this_event_data_field);
            (* increment pointer *)
            sptr_incr (buf_out/->id"cur") (size_of_ty event_struct_ty);
            sassign 
              (cid"bytes_written") 
              ((evar (cid"bytes_written") (tint 32))/+(eval@@vint (size_of_ty event_struct_ty) 32));
        ])
        tag_cids
        event_struct_tys);
    sret ((evar (cid"bytes_written") (tint 32)))
    ]
  in
  dfun (Cid.id fun_id) (tint 32) params body
;;

(* find the event type definition and put the deparser 
   right after it.
   The event type definition should appear after everything 
   it depends on.
   It would also be safe to put the deparser at the end, since its 
   not called by anything except the handler, as long as that's not already 
   implemented by this point in the compilation. *)
let rec process_inner decls = match decls with 
  | [] -> []
  | decl::decls -> (
    match decl.d with 
    | DTy(cid, Some(ty)) when Cid.equal cid (Cid.id (CCoreEvents.event_tunion_tyid)) -> 
      let event_t = tabstract_cid cid ty in
      let deparse_decl = deparse_fun event_t in
      decl::(deparse_decl::decls)
    | _ -> decl::(process_inner decls)
  )

let process decls = 
  process_inner decls
;;