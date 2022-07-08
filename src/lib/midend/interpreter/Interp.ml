open Batteries
open Syntax
open InterpState

let initial_state (pp : Preprocess.t) (spec : InterpSpec.t) =
  let nst =
    { (State.create spec.config) with
      event_sorts = Env.map fst pp.events
    ; switches = Array.init spec.num_switches (fun _ -> State.empty_state ())
    ; links = spec.links
    }
  in
  (* Add builtins *)
  List.iter
    (fun f -> State.add_global_function f nst)
    (System.defs @ Events.defs @ Counters.defs @ Arrays.defs @ PairArrays.defs);
  (* Add externs *)
  List.iteri
    (fun i exs -> Env.iter (fun cid v -> State.add_global i cid (V v) nst) exs)
    spec.externs;
  (* Add foreign functions *)
  Env.iter
    (fun cid fval ->
      Array.iteri (fun i _ -> State.add_global i cid fval nst) nst.switches)
    spec.extern_funs;
  (* Add events *)
  List.iter
    (fun (event, locs) ->
      List.iter
        (fun (loc, port) -> State.push_input_event loc port event nst)
        locs)
    spec.events;
  nst
;;

let initialize renaming spec_file ds =
  let pp, ds = Preprocess.preprocess ds in
  (* Also initializes the Python environment *)
  let spec = InterpSpec.parse pp renaming spec_file in
  let nst = initial_state pp spec in
  let nst = InterpCore.process_decls nst ds in
  nst, pp, spec
;;

(* 
  What does it take for an interactive interpreter? 
  - asynchronous processing. We need a background 
    process that modifies nst.event_queue...

  - Alternately...
    before processing each event, call a "read newline"
    function, that checks if there are any input events
    on stdin.

  - The problem is time... When an event comes in from stdin, 
    what time do we assign it? 
    - The only option that makes sense is "now" 
        -- the current simulation time. 


*)

let simulate_inner (nst : State.network_state) = 
  let rec interp_events idx nst =
    match State.next_time nst with
    | None -> nst
    | Some t ->
      let nst =
        if idx = 0
        then { nst with current_time = max t (nst.current_time + 1) }
        else nst
      in
      if nst.current_time > nst.config.max_time
      then nst
      else (
        match State.next_event idx nst with
        | None -> interp_events ((idx + 1) mod Array.length nst.switches) nst
        | Some (event, port) ->
          (match Env.find_opt event.eid nst.handlers with
          | None -> error @@ "No handler for event " ^ Cid.to_string event.eid
          | Some handler ->
            Printf.printf
              "t=%d: Handling %sevent %s at switch %d, port %d\n"
              nst.current_time
              (match Env.find event.eid nst.event_sorts with
              | EEntry _ -> "entry "
              | _ -> "")
              (CorePrinting.event_to_string event)
              idx
              port;
            handler nst idx port event);
          interp_events ((idx + 1) mod Array.length nst.switches) nst)
  in
  let nst = interp_events 0 nst in
  nst
;;

let simulate (nst : State.network_state) =
  Console.report
  @@ "Using random seed: "
  ^ string_of_int nst.config.random_seed
  ^ "\n";
  Random.init nst.config.random_seed;
  simulate_inner nst 
;;


(* run the interpreter in interactive mode 
  This means: 
  1. execute all the events in the spec file. 
  2. poll stdin for new events until it closes.

  Question:
    - how do we handle time? 
    option 1: simulated time. 
      - each new event executes at the simulation time when it is read, 
        and increments the clock by default_gap
    option 2: real time.
      - each new event executes now? 
      - each new event executes

*)
(* 
  left off here. 
    - Use PP and renaming to call event parser.
    - Signal the exit event handler to print output events.
*)
let run pp renaming spec (nst : State.network_state) =
   Random.init nst.config.random_seed;
  (* step 1: run the startup events *)
  let nst = simulate_inner nst in 

  (* step 2: poll for events and interpret them as they arrive from stdin *)
  print_endline @@ "startup complete. Waiting for events from sdtin";

  let rec poll_loop (nst : State.network_state) = 
    (* parse the event, give it a time of current_time *)
    print_endline "[poll_loop] polling for new event";
    let next_ev_opt = InterpStream.get_event_blocking 
      pp 
      renaming 
      spec 
      nst.current_time 
    in 
    match next_ev_opt with 
      | Some(ev, locs) -> 
        print_endline "[poll_loop] updating interpreter state";
        (* update interpreter state (push) *)        
        State.push_input_events locs ev nst;
        (* run the interpreter until there are no more events to process *)
        print_endline "[poll_loop] running interpreter";
        let nst = simulate_inner nst in 
        (* increment the time by input_gap *)
        (* repeat *)
        poll_loop nst
      | _ -> 
        print_endline "[poll_loop] EOF -- done polling";
        nst
  in 
  (* return final state *)
  poll_loop nst
;;
