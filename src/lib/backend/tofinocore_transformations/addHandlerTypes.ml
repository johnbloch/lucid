(* Transforms handlers from having parameters to having 
input and output events. (HParams to HEvent) *)

(*
  Also quantifies the names of:
    - parameter variables used in the body (prepend the input event's id)
    - event names in event assignments and generates (prepend the output event's id)
*)

open CoreSyntax
open TofinoCoreNew
open BackendLogging


(* context for this transformation pass: a list of events *)
module Ctx = Collections.IdMap
type ctx = {
  is_egress : bool;
  events : event Ctx.t;
}
let empty_ctx = { is_egress = false; events = Ctx.empty;}

(***find all the generate paths ***)
let find_generate_sequences stmt =
  let stmt_filter stmt = match stmt.s with
    | SGen (_, _) -> Some(stmt)
    | _ -> None
  in
  find_statement_paths [] stmt_filter stmt
;;


(* takes the body of a handler and its output eventset
   and computes the possible bitvectors for the output eventset *)
let generated_eventid_subsets (hdl_body:statement) =
  let generate_sequences = find_generate_sequences hdl_body in
  (* convert the generate sequences into sets of event ids *)
  let event_id_sequences = List.map
    (fun generate_sequence ->
      List.map id_of_generate generate_sequence)
    generate_sequences 
  in
  (* remove duplicate event id sequences *)
  let compare_id_seqs id_seq1 id_seq2 =
    let compare_ids id1 id2 = Id.compare id1 id2 in
    List.compare compare_ids id_seq1 id_seq2
  in

  let event_id_sequences = List.sort_uniq compare_id_seqs event_id_sequences in
  event_id_sequences
;;



(* find the generates in a statement *)
let rec find_generates (stmt : statement) : (gen_type * exp) list =
  match stmt.s with
  | SNoop | SUnit _ | SLocal _ | SAssign _ | SPrintf _ | SRet _ ->
      []
  | STableMatch _ | STableInstall _-> []
  | SIf (_, then_stmt, else_stmt) ->
      find_generates then_stmt @ find_generates else_stmt
  | SGen (gen_type, exp) -> [(gen_type, exp)]
  | SSeq (stmt1, stmt2) ->
      find_generates stmt1 @ find_generates stmt2
  | SMatch (_, branch_list) ->
      List.concat (List.map (fun (_, stmt) -> find_generates stmt) branch_list)
;;


(* derive the output event for this handler based on the generate statements *)
let derive_output_event (ctx:ctx) (hdl_id : id) (hdl_body:statement) : event =
  let generates = find_generates hdl_body in
  (* At this point, each generate expression should be an ecall, where the id 
     is the id of the event that it generates. We get that list of event ids. *)
  let event_ids = List.map (fun (_, exp) -> match exp.e with
    | ECall (cid, _) -> Cid.to_id cid
    | _ -> error "[addHandlerTypes.derive_output_type] generate expression should be an ecall") 
    generates 
  in
  (* now make the list of event ids unique *)
  let event_ids = List.sort_uniq Id.compare event_ids in
  (* now we look up the event ids in the context to get events *)
  let events = List.map (fun id -> match Ctx.find_opt id ctx.events with
    | Some e -> e
    | None -> error "[addHandlerTypes.derive_output_type] could not find event with same ID as generate expression") 
    event_ids
  in
  (* now we create an event set or union for the output. Ingress 
     is a set, because it may generate multiple events that are encoded 
     as one event. Whereas egress produces a union, because it only 
     generates one event. *)
  let eventset = if (ctx.is_egress)
    then EventUnion({
      evid = Id.append_string "_egress_output" hdl_id;
      members = events;})
    else EventSet({
      evid = Id.append_string "_ingress_output" hdl_id;
      members = events;
      subsets = generated_eventid_subsets hdl_body;})
  in
  eventset
;;

(* set the handler input and output events *)
let type_handler (ctx:ctx) hdl : handler * tdecl =  
  let _ = ctx in 
  match hdl with 
  | HParams ({hdl_id; hdl_sort; hdl_params; hdl_body}) ->
    let _ = hdl_params in 
    let input_event = match Ctx.find_opt hdl_id ctx.events with 
      | Some e -> e
      | None -> error "[addHandlerTypes.type_handler] could not find event with same ID as user-defined handler"  
    in
    let output_event = derive_output_event ctx hdl_id hdl_body in
    HEvent({hdl_id; 
      hdl_sort; 
      hdl_body=[hdl_body]; 
      hdl_input=input_event;
      hdl_output=output_event; 
      hdl_inparams=[]; 
      hdl_outparams=[];})
    , {td=TDEvent(output_event); tdspan = Span.default; tdpragma = None;}
  | _ -> error "[addHandlerTypes.type_handler] there shouldn't be any HEvent handlers at this point"

let rec type_handlers_in_tdecls ctx tdecls : tdecl list =
  match tdecls with
  | [] -> []
  | td :: tdecls' ->
    match td.td with
    (* type the handlers, possibly adding new decls for event types *)
    | TDHandler (hdl) -> 
      let hdl', hdl_out_event = type_handler ctx hdl in
      let td' = { td with td = TDHandler (hdl') } in
      hdl_out_event :: td' :: type_handlers_in_tdecls ctx tdecls'
    (* add events to the context *)
    | TDEvent(e) ->     
      let ctx' = {ctx with events=(Ctx.add (id_of_event e) e ctx.events);} in
      td :: type_handlers_in_tdecls ctx' tdecls
    (* leave all the other decls alone *)
    | _ -> td :: type_handlers_in_tdecls ctx tdecls'
;;

let type_handlers prog : prog =  
  List.map (fun component -> 
    match (Id.name component.comp_id) with
    | "ingress" -> 
      let ctx = { empty_ctx with is_egress = false } in
      { component with comp_decls = type_handlers_in_tdecls ctx component.comp_decls }
    | "egress" ->
      let ctx = { empty_ctx with is_egress = true } in
      { component with comp_decls = type_handlers_in_tdecls ctx component.comp_decls }
    | _ -> component)
    prog
;;