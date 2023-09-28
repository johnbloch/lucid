(* interpreter-specific extensions to core syntax: 
internal value and event types *)
open CoreSyntax
open InterpControl

(* values used in interpreter contexts. 'nst is network state *)
type 'nst ival =
  | V of value
  | F of 'nst code

and 'nst code = 'nst -> int (* switch *) -> 'nst ival list -> value

and memop

and 'nst handler =
'nst -> int (* switch *) -> int (* port *) -> event_val -> unit

let extract_ival iv =
  match iv with
  | V v -> v
  | F _ -> failwith "IVal not a regular value"
;;


(* internal event location in simulated network *)
type loc = {
  switch : int option;
  port : int;
}

(* an internal event in the interpreter *)
type internal_event = {
  sevent : event_val;
  sloc : loc; (*we always know where an event is located *)
  stime : int;
  squeue_order : int; (* tiebreaker for two events queued at the same time *)
}


let get_loc (ev : internal_event) = 
  ev.sloc
;;
let update_port (ev : internal_event) port' = 
  {ev with sloc = {ev.sloc with port = port'}}
;;

let get_port (ev : internal_event) =  ev.sloc.port
;;

let delay (ev : internal_event) = ev.sevent.edelay
;;

let timestamp internal_event = internal_event.stime
;;

let set_timestamp internal_event ts = 
  {internal_event with stime = ts}
;;
let loc (switch, port) = {switch; port}

let internal_event_to_string internal_event = 
  CorePrinting.event_to_string internal_event.sevent
;;


(* an input from the user *)
type interp_input =
  | IEvent of {iev : event_val; ilocs : loc list; itime : int}
  | IControl of {ictl : control_val; ilocs : loc list; itime : int}
;;
let ievent iev ilocs itime = IEvent{iev; ilocs; itime}
let icontrol ictl ilocs itime = IControl{ictl; ilocs; itime}
let interp_input_to_time interp_input = 
  match interp_input with
  | IEvent({itime}) -> itime
  | IControl({itime}) -> itime
;;
