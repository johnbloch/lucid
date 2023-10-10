(* The main interpreter library. Does initialization, user-polling, and event execution / simulator update loops. *)
open Batteries
open Yojson.Basic
open Syntax
open InterpSyntax
open InterpState
open InterpControl
open CoreSyntaxGlobalDirectory

let initial_state (pp : Preprocess.t) (spec : InterpSpec.t) =
  let nst =
    { (State.create spec.config) with
      event_sorts = Env.map (fun (a, _, _) -> a) pp.events
    ; event_signatures  = List.fold_left
        (fun acc (evid, event) -> 
          let (_, num_opt, arg_tys) = event in
          (match num_opt with 
          | None -> print_endline ("event has no number: " ^ (Cid.to_string evid)); 
          | _ -> ());
          let num = Option.get num_opt in
          IntMap.add num (evid, arg_tys) acc)
        IntMap.empty
        (Env.bindings pp.events)
    ; switches = Array.init spec.num_switches 
      (InterpSwitch.create spec.config State.network_utils)
    ; links = spec.links
    }
  in
  (* Add builtins *)
  List.iter
    (fun f -> State.add_global_function f nst)
    (System.defs @ Events.defs @ Counters.defs @ Arrays.defs @ PairArrays.defs @Payloads.defs);
  (* Add externs *)
  List.iteri
    (fun i exs -> Env.iter (fun cid v -> State.add_global i cid (V v) nst) exs)
    spec.externs;
  (* Add foreign functions *)
  Env.iter
    (fun cid fval ->
      Array.iteri (fun i _ -> State.add_global i cid fval nst) nst.switches)
    spec.extern_funs;
  (* Add error-raising function for background event parser *)
  let bg_parse_cid = Cid.id Builtins.lucid_parse_id in 
  let bg_parse_fun = InterpPayload.lucid_parse_fun in
  Array.iteri
    (fun swid _ -> State.add_global swid bg_parse_cid (F bg_parse_fun) nst)
    nst.switches
  ;
  (* push interpreter inputs to ingress and control command queues *)
  State.load_interp_inputs nst spec.events;

  nst
;;

let initialize renaming spec_file ds =
  let pp, ds = Preprocess.preprocess ds in
  (* Also initializes the Python environment *)
  let spec = InterpSpec.parse pp renaming spec_file in
  let nst = initial_state pp spec in
  let nst = InterpCore.process_decls nst ds in
  (* initialize the global name directory *)
  let nst =
    { nst with global_names = CoreSyntaxGlobalDirectory.build_coredirectory ds }
  in
  nst, pp, spec
;;

(*** innermost functions of interpretation loop: execute one
     event or control op, then call a function to continue interpretation ***)
let execute_event
  print_log
  swid
  (nst : State.network_state)
  (event : CoreSyntax.event_val)
  port
  gress
  =
  let handlers, gress_str = match gress with 
  | InterpSwitch.Egress -> nst.egress_handlers, " egress "
  | InterpSwitch.Ingress -> nst.handlers, ""
  in
  match Env.find_opt event.eid handlers with
  (* if we found a handler, run it *)
  | Some handler ->
    if print_log
    then
      if Cmdline.cfg.json || Cmdline.cfg.interactive
      then
        `Assoc
          [ ( "event_arrival"
            , `Assoc
                [ "switch", `Int swid
                ; "port", `Int port
                ; "time", `Int nst.current_time
                ; "event", `String (CorePrinting.event_to_string event) ] ) ]
        |> Yojson.Basic.pretty_to_string
        |> print_endline
      else
        Printf.printf
          "t=%d: Handling %s%sevent %s at switch %d, port %d\n"
          nst.current_time
          gress_str
          (match Env.find event.eid nst.event_sorts with
          | EPacket -> "packet "
          | _ -> "")
          (CorePrinting.event_to_string event)
          swid
          port;
    handler nst swid port event  
  (* if we didn't find a handler, that's an error for ingress but okay for egress. *)
  | None -> (
    match gress with
    | InterpSwitch.Egress -> 
      (* add propagation delay and push to destination *)
      (* run a default handling statement that re-serializes the event and 
         pushes it to the next switch.*)
      let builtin_env = Env.add (Id (Builtins.ingr_port_id)) (InterpSyntax.V (C.vint port 32)) Env.empty in
      (* print_endline@@"t="^(string_of_int nst.current_time)^" running default egress handler for event " ^ Cid.to_string event.eid ^ " at switch " ^ (string_of_int swid) ^ " port " ^ (string_of_int port); *)
      let default_handler_body = 
        C.SGen(C.GPort(C.vint_exp port 32), C.value_to_exp {v=C.VEvent(event); vty=C.ty TEvent; vspan=Span.default})
      in      
      ignore@@InterpCore.interp_statement nst HEgress swid builtin_env (C.statement default_handler_body)
    | InterpSwitch.Ingress ->    
      error @@ "No handler for event " ^ Cid.to_string event.eid )
;;

let execute_main_parser print_log swidx port (nst: State.network_state) (pkt_ev : (CoreSyntax.event_val)) = 
  let payload_val = List.hd pkt_ev.data in
  (* main takes 2 arguments, port and payload. Port is implicit. *)
  let main_args = [InterpSyntax.V (C.vint port 32); InterpSyntax.V payload_val] in
  let main_parser = State.lookup swidx (Cid.id Builtins.main_parse_id) nst in

  match main_parser with 
    | F parser_f -> (
      if print_log
        then
          if Cmdline.cfg.json || Cmdline.cfg.interactive
          then
            `Assoc
              [ ( "packet_arrival"
                , `Assoc
                    [ "switch", `Int swidx
                    ; "port", `Int port
                    ; "time", `Int nst.current_time
                    ; "bytes", `String (CorePrinting.value_to_string payload_val) ] ) ]
            |> Yojson.Basic.pretty_to_string
            |> print_endline
          else
            Printf.printf
              "t=%d: Parsing packet %s at switch %d, port %d\n"
              nst.current_time
              (CorePrinting.value_to_string payload_val)
              swidx
              port;
      let event_val = parser_f nst swidx main_args in
      match event_val.v with 
      | VEvent(event_val) -> execute_event print_log swidx nst event_val port (InterpSwitch.Ingress)
      | VBool(false) -> error "main parser did not generate an event"
      | _ -> error "main parser did not return an event or a no event signal")
    | _ -> error "the global named 'main' is not a parser"
;;   

let execute_control swidx (nst : State.network_state) (ctl_ev : control_val) =
  InterpControl.handle_control (State.pipe nst swidx) nst.global_names ctl_ev
;;


let run_event_tup print_log idx nst ((event:CoreSyntax.event_val), port, gress) = 
  if (not event.eserialized) then 
    execute_event print_log idx nst event port gress
  else 
  execute_main_parser print_log idx port nst event
;;

let run_event_at_time print_log idx nst (ievent, port, event_time, gress) = 
  let nst = {nst with State.current_time=event_time} in
  run_event_tup print_log idx nst (ievent, port, gress)
;;

let execute_interp_event
  print_log
  simulation_callback
  idx
  (nst : State.network_state)
  events
  =
  List.iter (run_event_tup print_log idx nst) events;
  simulation_callback ((idx + 1) mod Array.length nst.switches) nst
;;

(* run all the egress events from all of the switches *)
let run_egress_events print_log (nst:State.network_state) = 
  Array.iteri 
    (fun swid _ -> 
        let egr_evs = State.ready_egress_events swid nst in
        List.iter (run_event_tup print_log swid nst) egr_evs;
    )
  nst.switches
;;

let finish_egress_events print_log (nst:State.network_state) = 
  Array.iteri 
    (fun swid _ -> 
        let egr_evs = State.all_egress_events swid nst in
        List.iter (run_event_at_time print_log swid nst) egr_evs;
    )
  nst.switches
;;

(* execute all the control commands at the switch *)
let execute_ready_controls swid (nst : State.network_state) =
  List.iter 
    (execute_control swid nst) 
    (State.ready_control_commands swid nst)
;;

let advance_current_time next_event_time (nst: State.network_state) = 
  (* advance the current time of the network to the time of the
     next queued event, unless the event is queued at the 
     current time, in which case we advance the current time 
     by 1.
     If you run this at the start of processing an event from each 
     switch, it models being able to process 1 event per time unit. *)
  {nst with current_time = max next_event_time (nst.current_time + 1)}
;;

let rec execute_sim_step idx nst = 
  (* execute a step of the simulation *)
  match State.next_time nst with
  (* no time at which some switch has a thing to do? then nothing will ever change. *)
  | None -> nst
  | Some next_event_time -> (
    (* special processing when you are at the first switch *)
    let nst = if (idx = 0) 
      then (
        let nst = advance_current_time next_event_time nst in
        run_egress_events true nst;
        nst)
      else nst
    in
    if nst.current_time > nst.config.max_time
      then nst
      else (
        (* run any control events *)
        execute_ready_controls idx nst;
        (* check for ingress and egress events with time < nst.current_time *)
        match State.next_ready_event idx nst with
        | Some (epgs) -> execute_interp_event true execute_sim_step idx nst epgs
        | None -> execute_sim_step ((idx + 1) mod Array.length nst.switches) nst
      )    
  )
;;

let simulate (nst : State.network_state) =
  if (not Cmdline.cfg.json) && not Cmdline.cfg.interactive
  then
    Console.report
    @@ "Using random seed: "
    ^ string_of_int nst.config.random_seed
    ^ "\n";
  Random.init nst.config.random_seed;
  let nst = execute_sim_step 0 nst in
  (* drain all the egresses one last time to get everything into an ingress queue for logging *)
  finish_egress_events true nst;
  nst
;;

(** interactive mode (stdio) implementation
  Interactive mode behavior notes:
    - Input:
      - expects every event to be a json dictionary on its own line
      - waits for eof
    - Execution:
      - starts polling stdin after max_time has elapsed
      - polls stdin for new events once per time unit
      - events on stdin execute at time = max(current_ts, event.timestamp)
    - Output:
      - prints each exit event to stdout as a json, one event per line
      - all printfs in the program print to stderr
**)

type event_getter = int -> InterpSyntax.interp_input list

(* interp events until max_time is reached
   or there are no more events to interpret *)

let load_new_events nst event_getter_opt = 
  match event_getter_opt with
  | None -> ()
  | Some(event_getter) -> 
    State.load_interp_inputs nst (event_getter nst.current_time) ;
;;
(* execute a step of the simulation running in interactive mode *)
let rec execute_interactive_sim_step event_getter_opt max_time idx nst = 
  let next_step_continuation = execute_interactive_sim_step event_getter_opt max_time in
  match State.next_time nst with
  (* no time at which some switch has a thing to do? then nothing will ever change. *)
  | None -> nst
  | Some t -> 
    let nst = if (idx = 0)
      then (
    run_egress_events true nst;
        load_new_events nst event_getter_opt;
        advance_current_time t nst)
      else nst
    in
    if max_time > -1 && nst.current_time > max_time
      then nst
    else 
      match State.next_ready_event idx nst with
      | Some (epgs) ->
        execute_ready_controls idx nst;
        execute_interp_event true next_step_continuation idx nst epgs
      (* if there's no next event, move to the next switch *)
      | None -> next_step_continuation ((idx + 1) mod Array.length nst.switches) nst
;;

let sighdl s =
  print_endline ("got signal " ^ string_of_int s);
  if s != -14 then exit 1
;;

(* this type should be refactored out *)
type interactive_mode_input =
  | Process of interp_input list
  | Continue
  | End

(* create a pipe for control commands *)
let create_control_pipe ctl_pipe_name =
  prerr_endline ("using control pipe: " ^ ctl_pipe_name);
  let exists =
    try
      Unix.access ctl_pipe_name [Unix.F_OK];
      true
    with
    | Unix.Unix_error _ -> false
  in
  (* we can mkfifo if file is fifo or does not exist *)
  let okay_to_mkfifo =
    if not exists
    then true
    else (
      let stats = Unix.stat ctl_pipe_name in
      if stats.st_kind <> Unix.S_FIFO
      then
        error
        @@ "the control pipe file "
        ^ ctl_pipe_name
        ^ " already exists, and is not a named pipe. "
        ^ " please delete it or use another file."
      else true)
  in
  if okay_to_mkfifo
  then (
    try Unix.mkfifo ctl_pipe_name 0o664 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | e -> raise e)
  else error "could not create named pipe to controller";
  let ctl_fd = Unix.openfile ctl_pipe_name [Unix.O_RDONLY; Unix.O_NONBLOCK] 0 in
  ctl_fd
;;

(* Run the interpreter in interactive mode. *)
let run pp renaming (spec : InterpSpec.t) (nst : State.network_state) =
  let all_fds =
    match spec.ctl_pipe_name with
    | Some ctl_pipe_name -> [Unix.stdin; create_control_pipe ctl_pipe_name]
    | None -> [Unix.stdin]
  in
  (* get a single input from either stdin or the control pipe *)
  let get_input pp renaming num_switches current_time twait =
    (* poll stdin and the control pipe for input *)
    let read_fds, _, _ =
      try Unix.select all_fds [] [] twait with
      | Unix.Unix_error (err, fname, arg) ->
        (match err with
         | Unix.EBADF ->
           ( []
           , []
           , [] (* supposed to happen when stdin closes, but not sure of that.*)
           )
         | _ -> error @@ "[get_input] unix error: " ^ fname ^ "(" ^ arg ^ ")")
    in
    (* this part sould be cleaned up, but it may be a bit delicate with the file descriptors. *)
    (* if stdin has input available, read it *)
    if List.mem Unix.stdin read_fds
    then (
      try
        let ev_str = input_line stdin in
        let ev_json = Yojson.Basic.from_string ev_str in
        let located_events =
          InterpSpec.parse_interp_event_list
            pp
            renaming
            num_switches
            current_time
            ev_json
        in
        (* let located_event = InterpSpec.parse_interp_input pp renaming num_switches current_time ev_json in  *)
        Process located_events
      with
      | _ ->
        End
        (* if reading from stdin fails, we want to exit *)
        (* if there are any other input pipes (i.e., the control pipe), read a command from it *))
    else if List.length all_fds = 2 && List.mem (List.nth all_fds 1) read_fds
    then (
      try
        let ctl_fd = List.nth all_fds 1 in
        let ev_str = input_line (Unix.in_channel_of_descr ctl_fd) in
        let ev_json = Yojson.Basic.from_string ev_str in
        let located_events =
          InterpSpec.parse_interp_event_list
            pp
            renaming
            num_switches
            current_time
            ev_json
        in
        (* let located_event = InterpSpec.parse_interp_input pp renaming num_switches current_time ev_json in  *)
        Process located_events
      with
      (* if reading from anything besides stdin fails, we don't want to exit because there's still stdin.. *)
      (* TODO -- lol clean that up *)
      | End_of_file -> Continue
      | e ->
        let _ = e in
        error "error reading from control pipe (NOT an EOF)")
    else Continue
  in
  (* get up to n inputs. For any inputs that are events,
     queue the events for processing. For any inputs that are
     commands, execute them immediately. *)
  let get_events_nonblocking pp renaming num_switches n current_time =
    let located_events =
      List.filter_map
        (fun _ ->
          match get_input pp renaming num_switches current_time 0.0 with
          | Process e -> Some e
          | _ -> None)
        (MiscUtils.range 0 n)
    in
    List.flatten located_events
  in
  (* wait for 1 event or eof *)
  let get_input_blocking pp renaming num_switches current_time =
    let res = get_input pp renaming num_switches current_time (-1.0) in
    res
  in
  (* function to get a batch of events that arrive while interpreter is executing *)
  let event_getter =
    get_events_nonblocking pp renaming spec.num_switches spec.num_switches
  in
  let rec poll_loop (nst : State.network_state) =
    (* wait for a single event or command *)
    let input =
      get_input_blocking pp renaming spec.num_switches nst.current_time
    in
    match input with
    | End -> nst (* end *)
    | Continue -> poll_loop nst
    | Process evs -> 
      State.load_interp_inputs nst evs;
      (* interpret all the queued events, using event_getter to poll for more events
           in between iterations. *)
      let nst = execute_interactive_sim_step (Some event_getter) (-1) 0 nst in
      poll_loop nst
  in
  Random.init nst.config.random_seed;
  (* interp events with no event getter to initialize network, then run the polling loop *)
  let nst = execute_interactive_sim_step None nst.config.max_time 0 nst in
  poll_loop nst
;;
