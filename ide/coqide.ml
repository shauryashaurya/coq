open Vernacexpr
open Coq
open Ideutils

  
let out_some s = match s with | None -> assert false | Some f -> f

let yes_icon = "gtk-yes"
let no_icon = "gtk-no"
let save_icon = "gtk-save"
let saveas_icon = "gtk-save-as"

let window_width = 1280
let window_height = 1024

let initial_cwd = Sys.getcwd ()

let default_general_font_name = "Sans 14"
let default_monospace_font_name = "Monospace 14"

let manual_monospace_font = ref None
let manual_general_font = ref None

let has_config_file = (Sys.file_exists ".coqiderc") || 
		      (try Sys.file_exists (Filename.concat (Sys.getenv "HOME") ".coqiderc")
		       with Not_found -> false)

let _ = if not has_config_file then 
  manual_monospace_font := Some (Pango.Font.from_string default_monospace_font_name);
  manual_general_font := Some (Pango.Font.from_string default_general_font_name)


let (font_selector:GWindow.font_selection_dialog option ref) = ref None
let (message_view:GText.view option ref) = ref None
let (proof_view:GText.view option ref) = ref None

let (_notebook:GPack.notebook option ref) = ref None
let notebook () = out_some !_notebook

let decompose_tab w = 
  let vbox = new GPack.box ((Gobject.try_cast w "GtkBox"):Gtk.box Gtk.obj) in
  let l = vbox#children in
  match l with 
    | [img;lbl] -> 
	let img = new GMisc.image 
		    ((Gobject.try_cast img#as_widget "GtkImage"):
		       Gtk.image Gtk.obj) 
	in
	let lbl = GMisc.label_cast lbl in
	vbox,img,lbl
    | _ -> assert false
	
let set_tab_label i n =
  let nb = notebook () in
  let _,_,lbl = decompose_tab (nb#get_tab_label(nb#get_nth_page i))#as_widget in
  lbl#set_markup n

let set_tab_image i s = 
  let nb = notebook () in
  let _,img,_ = decompose_tab (nb#get_tab_label(nb#get_nth_page i))#as_widget in
  img#set_stock s ~size:1

let set_current_tab_image s = set_tab_image (notebook())#current_page s
  
let set_current_tab_label n = 
  set_tab_label (notebook())#current_page n 

let get_tab_label i =
  let nb = notebook () in
  let _,_,lbl = decompose_tab (nb#get_tab_label(nb#get_nth_page i))#as_widget in
  lbl#text

let get_current_tab_label () = get_tab_label (notebook())#current_page

let reset_tab_label i = set_tab_label i (get_tab_label i)

module Vector = struct 
  type 'a t = 'a array ref
  let create () = ref [||]
  let get t = Array.get !t
  let set t = Array.set !t
  let append t e = t := Array.append !t [|e|]; (Array.length !t)-1
  let iter f t =  Array.iter f !t
  let exists f t =
    let l = Array.length !t in
    let rec test i = i < l && (f !t.(i) || test (i+1)) in 
    test 0
end

type viewable_script =
    {view : GText.view;
     mutable deactivate : unit -> unit;
     mutable activate : unit -> unit;
     mutable filename : string option
    }

let (input_views:viewable_script Vector.t) = Vector.create ()

let crash_save i =
  Pervasives.prerr_endline "Trying to save all buffers in .crashcoqide files";
  let count = ref 0 in 
  Vector.iter 
    (function {view=view;filename=filename} -> 
       let filename = match filename with 
	 | None -> incr count; "Unamed_coqscript_"^(string_of_int !count)^".crashcoqide"
	 | Some f -> f^".crashcoqide"
       in
       try 
	 try_export filename (view#buffer#get_text ());
	 Pervasives.prerr_endline ("Saved "^filename)
       with _ -> Pervasives.prerr_endline ("Could not save "^filename)
    )
    input_views;
  Pervasives.prerr_endline "Done. Please report.";
  exit i

let _ = 
  let signals_to_catch = [Sys.sigabrt; Sys.sigalrm; Sys.sigfpe; Sys.sighup; Sys.sigill; 
			  Sys.sigint; Sys.sigpipe; Sys.sigquit; Sys.sigsegv; 
			  Sys.sigterm; Sys.sigusr2] 
  in List.iter (fun i -> Sys.set_signal i (Sys.Signal_handle crash_save)) signals_to_catch

let add_input_view tv = 
  Vector.append input_views tv

let get_input_view i = Vector.get input_views i

let active_view = ref None

let get_active_view () = Vector.get input_views (out_some !active_view)

let set_active_view i = 
  (match !active_view with  None -> () | Some i -> 
     reset_tab_label i);
  (notebook ())#goto_page i; 
  let txt = get_current_tab_label () in
  set_current_tab_label ("<span background=\"light green\">"^txt^"</span>");
  active_view := Some i

(* let kill_input_view i = 
  if (Array.length !input_views) <= 1 then input_views := [||]
  else
    let r = Array.create (Array.length !input_views) !input_views.(0) in
    Array.iteri (fun j tv -> 
		   if j < i then r.(j) <- !input_views.(j) 
		   else if j > i then r.(j-1) <- !input_views.(j))
      !input_views;
    input_views := r
*)

let get_current_view () = Vector.get input_views (notebook ())#current_page

let status = ref None
let push_info = ref (function s -> failwith "not ready")
let pop_info = ref (function s -> failwith "not ready")
let flash_info = ref  (function s -> failwith "not ready")

let input_channel b ic =
  let buf = String.create 1024 and len = ref 0 in
  while len := input ic buf 0 1024; !len > 0 do
    Buffer.add_substring b buf 0 !len
  done

let with_file name ~f =
  let ic = open_in name in
  try f ic; close_in ic with exn -> close_in ic; raise exn

type info =  {start:GText.mark;
	      stop:GText.mark;
	      ast:Util.loc * Vernacexpr.vernac_expr;
	      reset_info:Coq.reset_info;
	     }

exception Size of int
let (processed_stack:info Stack.t) = Stack.create ()
let push x = Stack.push x processed_stack
let pop () = try Stack.pop processed_stack with Stack.Empty -> raise (Size 0)
let top () = try Stack.top processed_stack with Stack.Empty -> raise (Size 0)
let is_empty () = Stack.is_empty processed_stack

(* push a new Coq phrase *)

let update_on_end_of_proof () =
  let lookup_lemma = function
  | { ast = _, ( VernacDefinition (_, _, ProveBody _, _, _)
	       | VernacStartTheoremProof _) ; reset_info = Reset (_, r) } ->
      r := true; raise Exit
  | { ast = _, (VernacAbort _ | VernacAbortAll) } -> raise Exit
  | _ -> ()
  in
  try Stack.iter lookup_lemma processed_stack with Exit -> ()

let update_on_end_of_segment id =
  let lookup_section = function 
    | { ast = _, ( VernacBeginSection id'
		 | VernacDefineModule (id',_,_,None)
		 | VernacDeclareModule (id',_,_,None)
		 | VernacDeclareModuleType (id',_,None)); 
	reset_info = Reset (_, r) } 
      when id = id' -> raise Exit
    | { reset_info = Reset (_, r) } -> r := false
    | _ -> ()
  in
  try Stack.iter lookup_section processed_stack with Exit -> ()

let push_phrase start_of_phrase_mark end_of_phrase_mark ast = 
  let x = {start = start_of_phrase_mark;
	   stop = end_of_phrase_mark;
	   ast = ast;
	   reset_info = Coq.compute_reset_info (snd ast)} in
  push x;
  match snd ast with
    | VernacEndProof (_, None) -> update_on_end_of_proof ()
    | VernacEndSegment id -> update_on_end_of_segment id
    | _ -> ()

let repush_phrase x =
  let x = { x with reset_info = Coq.compute_reset_info (snd x.ast) } in
  push x;
  match snd x.ast with
    | VernacEndProof (_, None) -> update_on_end_of_proof ()
    | VernacEndSegment id -> update_on_end_of_segment id
    | _ -> ()

(* For electric handlers *)
exception Found

(* For find_phrase_starting_at *)
exception Stop of int

let set_break () = 
  Sys.set_signal Sys.sigusr1 (Sys.Signal_handle (fun _ -> raise Sys.Break))
let unset_break () = 
  Sys.set_signal Sys.sigusr1 Sys.Signal_ignore

(* Signal sigusr1 is used to stop coq computation *)
let pid = Unix.getpid ()
let break () = Unix.kill pid Sys.sigusr1
let can_break () = set_break () 
let cant_break () = unset_break () 

(* Get back the standard coq out channels *)
let read_stdout,clear_stdout =
  let out_buff = Buffer.create 100 in
  Pp_control.std_ft := Format.formatter_of_buffer out_buff;
  (fun () -> Format.pp_print_flush !Pp_control.std_ft (); 
     let r = Buffer.contents out_buff in
     Buffer.clear out_buff; r),
  (fun () -> 
     Format.pp_print_flush !Pp_control.std_ft (); Buffer.clear out_buff)

let find_tag_limits (tag :GText.tag) (it:GText.iter) = 
    (if not (it#begins_tag (Some tag)) 
     then it#backward_to_tag_toggle (Some tag)
     else it#copy),
    (if not (it#ends_tag (Some tag))
     then it#forward_to_tag_toggle (Some tag)
     else it#copy)

let rec analyze_all index =
  let {view = input_view } as current_all = get_input_view index in
  let (proof_view:GText.view) = out_some !proof_view in
  let (message_view:GText.view) = out_some !message_view in
  let input_buffer = input_view#buffer in
  let proof_buffer = proof_view#buffer in
  let message_buffer = message_view#buffer in
  let insert_message s =
    message_buffer#insert s;
    message_view#misc#draw None
  in
  let set_message s =
    message_buffer#set_text s;
    message_view#misc#draw None
  in
  let clear_message () = message_buffer#set_text ""
  in
  ignore (message_buffer#connect#after#insert_text
	    ~callback:(fun it s -> ignore 
			 (message_view#scroll_to_mark
			    ~within_margin:0.49
			    `INSERT)));
  let last_index = ref true in
  let last_array = [|"";""|] in
  let get_start_of_input () = 
    input_buffer#get_iter_at_mark 
      (`NAME "start_of_input") 
  in
  ignore (input_buffer#connect#modified_changed
	 ~callback:(fun () ->
		      if input_buffer#modified then 
			set_tab_image index 
			  (match current_all.filename with 
			     | None -> saveas_icon
			     | Some _ -> save_icon
			  )
		      else set_tab_image index yes_icon;
		   ));
  ignore (input_buffer#connect#changed
	    ~callback:(fun () -> 
			 input_buffer#remove_tag_by_name 
			 ~start:(get_start_of_input())
			 ~stop:input_buffer#end_iter
			 "error";
			 Highlight.highlight_current_line input_buffer));
  let get_insert () = get_insert input_buffer in
  let recenter_insert () = ignore (input_view#scroll_to_iter 
				     ~within_margin:0.10 
				     (get_insert ())) 
  in
  let rec show_goals () = 
    proof_view#buffer#set_text "";
    let s = Coq.get_curent_goals () in
    let last_shown_area = proof_buffer#create_tag [`BACKGROUND "light blue"]
    in
    match s with 
      | [] -> proof_buffer#insert (Coq.print_no_goal ())
      | (hyps,concl)::r -> 
	  let goal_nb = List.length s in
	  proof_buffer#insert (Printf.sprintf "%d subgoal%s\n" 
				 goal_nb
				 (if goal_nb<=1 then "" else "s"));
	  let coq_menu commands = 
	    let tag = proof_buffer#create_tag []
	    in 
	    ignore
	      (tag#connect#event ~callback:
		 (fun ~origin ev it ->
		    match GdkEvent.get_type ev with 
		      | `BUTTON_PRESS -> 
			  let ev = (GdkEvent.Button.cast ev) in
			  if (GdkEvent.Button.button ev) = 3 
			  then begin 
			    let loc_menu = GMenu.menu () in
			    let factory = new GMenu.factory loc_menu in
			    let add_coq_command (cp,ip) = 
			      ignore (factory#add_item cp 
					~callback:
					(fun () -> ignore
					   (insert_this_phrase_on_success 
					      true
					      true 
					      false 
					      (ip^"\n") 
					      (ip^"\n"))
					)
				     )
			    in
			    List.iter add_coq_command commands;
			    loc_menu#popup 
			      ~button:3
			      ~time:(GdkEvent.Button.time ev);
			  end
		      | `MOTION_NOTIFY -> 
			  proof_buffer#remove_tag
			  ~start:proof_buffer#start_iter
			  ~stop:proof_buffer#end_iter
			  last_shown_area;
			  let s,e = find_tag_limits tag 
				      (new GText.iter it) 
			  in
			  proof_buffer#apply_tag 
			    ~start:s 
			    ~stop:e 
			    last_shown_area;
			  ()
		      | _ -> ())
	      );
	    tag
	  in
	  List.iter
	    (fun ((_,_,_,(s,_)) as hyp) -> 
	       let tag = coq_menu (hyp_menu hyp) in
	       proof_buffer#insert ~tags:[tag] (s^"\n"))
	    hyps;
	  proof_buffer#insert ("---------------------------------------(1/"^
			       (string_of_int goal_nb)^
			       ")\n") 
	  ;
	  let tag = coq_menu (concl_menu concl) in
	  let _,_,_,sconcl = concl in
	  proof_buffer#insert ~tags:[tag] sconcl;
	  proof_buffer#insert "\n";
	  let my_mark = `NAME "end_of_conclusion" in
	  proof_buffer#move_mark
	    ~where:((proof_buffer#get_iter_at_mark `INSERT)) my_mark;
	  proof_buffer#insert "\n\n";
	  let i = ref 1 in
	  List.iter 
	    (function (_,(_,_,_,concl)) -> 
	       incr i;
	       proof_buffer#insert ("--------------------------------------("^
				    (string_of_int !i)^
				    "/"^
				    (string_of_int goal_nb)^
				    ")\n");
	       proof_buffer#insert concl;
	       proof_buffer#insert "\n\n";
	    )
	    r;
	  ignore (proof_view#scroll_to_mark my_mark) 
  and send_to_coq phrase show_output show_error localize =
    try
      !push_info "Coq is computing";
      (out_some !status)#misc#draw None;
      input_view#set_editable false;
      can_break ();
      let r = Some (Coq.interp phrase) in
      cant_break ();
      input_view#set_editable true;
      !pop_info ();
      (out_some !status)#misc#draw None;
      let msg = read_stdout () in 
      insert_message (if show_output then msg else "");
      r
    with e ->
      input_view#set_editable true;
      !pop_info ();
      (if show_error then
	 let (s,loc) = Coq.process_exn e in
	 assert (Glib.Utf8.validate s);
	 set_message s;
	 message_view#misc#draw None;
	 if localize then 
	   (match loc with 
	      | None -> ()
	      | Some (start,stop) -> 
		  let convert_pos = byte_offset_to_char_offset phrase in
		  let start = convert_pos start in
		  let stop = convert_pos stop in
		  let i = get_start_of_input() in 
		  let starti = i#forward_chars start in
		  let stopi = i#forward_chars stop in
		  input_buffer#apply_tag_by_name "error"
   		    ~start:starti
		    ~stop:stopi
	   ));
      None
  and find_phrase_starting_at (start:GText.iter) = 
    let trash_bytes = ref "" in
    let end_iter = start#copy in
    let lexbuf_function s count =
      let i = ref 0 in
      let n_trash = String.length !trash_bytes in
      String.blit !trash_bytes 0 s 0 n_trash;
      i := n_trash;
      try
	while !i <= count - 1 do
	  let c = end_iter#char in
	  if c = 0 then raise (Stop !i);
	  let c' = Glib.Utf8.from_unichar c in
	  let n = String.length c' in
	  if n > count - !i  then 
	    begin
	      let ri = count - !i in
	      String.blit c' 0 s !i ri;
	      trash_bytes := String.sub c' ri (n-ri);
	      i := count ;
	    end else begin
	      String.blit c' 0 s !i n;
	      i:= !i + n
	    end;
	  if not end_iter#nocopy#forward_char then 
	    raise (Stop !i)
	done;
	count
      with Stop x -> x
    in
    try
      Find_phrase.length := 0;
      trash_bytes := "";
      let phrase = Find_phrase.next_phrase (Lexing.from_function lexbuf_function) in
      end_iter#nocopy#set_offset (start#offset + !Find_phrase.length);
      Some (start,end_iter)
    with _ -> None
  and process_next_phrase display_goals = 
    clear_message ();
    match (find_phrase_starting_at (get_start_of_input ()))
    with None -> false
      | Some(start,stop) ->
	  let b = input_buffer in
	  let phrase = start#get_slice ~stop in
	  match send_to_coq phrase true true true with
	    | Some ast ->
		begin
		  b#move_mark ~where:stop (`NAME "start_of_input");
		  b#apply_tag_by_name "processed" ~start ~stop;
		  if ((get_insert())#compare) stop <= 0 then 
		    begin
		      b#place_cursor stop;
		      recenter_insert () 
		    end;
		  let start_of_phrase_mark = `MARK (b#create_mark start) in
		  let end_of_phrase_mark = `MARK (b#create_mark stop) in
		  push_phrase start_of_phrase_mark end_of_phrase_mark ast;
		  if display_goals then
		    (try show_goals () with e -> 
		       prerr_endline (Printexc.to_string e);());
		  true;
		end
	    | None -> false
  and insert_this_phrase_on_success 
    show_output show_msg localize coqphrase insertphrase = 
    match send_to_coq coqphrase show_output show_msg localize with
      | Some ast ->
	  begin
	    let stop = get_start_of_input () in
	    if stop#starts_line then
	      input_buffer#insert ~iter:stop insertphrase
	    else input_buffer#insert ~iter:stop ("\n"^insertphrase); 
	    let start = get_start_of_input () in
	    input_buffer#move_mark ~where:stop (`NAME "start_of_input");
	    input_buffer#apply_tag_by_name "processed" ~start ~stop;
	    if ((get_insert())#compare) stop <= 0 then 
	      input_buffer#place_cursor stop;
	    let start_of_phrase_mark = `MARK (input_buffer#create_mark start) in
	    let end_of_phrase_mark = `MARK (input_buffer#create_mark stop) in
	    push_phrase start_of_phrase_mark end_of_phrase_mark ast;
	    (try show_goals () with e -> ());
	    true
	  end
      | None -> insert_message ("Unsuccesfully tried: "^coqphrase);
	  false
  in
  let process_until_iter_or_error stop =
    let start = (get_start_of_input ())#copy in
    input_buffer#apply_tag_by_name 
      ~start
      ~stop
      "to_process";
    while ((stop#compare (get_start_of_input ())>=0) && process_next_phrase false)
    do () done;
    (try show_goals () with _ -> ());
    input_buffer#remove_tag_by_name ~start ~stop "to_process" ;

  in  
  let process_until_insert_or_error () = 
    let stop = get_insert () in
    process_until_iter_or_error stop
  in  
  let reset_initial () = 
    Stack.iter 
      (function inf -> 
	 let start = input_buffer#get_iter_at_mark inf.start in
	 let stop = input_buffer#get_iter_at_mark inf.stop in
	 input_buffer#move_mark ~where:start (`NAME "start_of_input");
	 input_buffer#remove_tag_by_name "processed" ~start ~stop;
	 input_buffer#delete_mark inf.start;
	 input_buffer#delete_mark inf.stop;
      ) 
      processed_stack;
    Stack.clear processed_stack;
    clear_message ();
    Coq.reset_initial ()
  in
  (* backtrack Coq to the phrase preceding iterator [i] *)
  let backtrack_to i = 
    (* re-synchronize Coq to the current state of the stack *)
    let rec synchro () =
      if is_empty () then
	Coq.reset_initial ()
      else begin
	let t = pop () in
	begin match t.reset_info with
	  | Reset (id, ({contents=true} as v)) -> v:=false; reset_to id
	  | _ -> synchro ()
	end;
	interp_last t.ast;
	repush_phrase t
      end
    in
    (* pop Coq commands until we reach iterator [i] *)
    let add_undo = function Some n -> Some (succ n) | None -> None in
    let rec pop_commands done_smthg undos =
      if is_empty () then 
	done_smthg, undos
      else
	let t = top () in 
	if i#compare (input_buffer#get_iter_at_mark t.stop) < 0 then begin
	  ignore (pop ());
	  let undos = if is_tactic (snd t.ast) then add_undo undos else None in
	  pop_commands true undos
	end else
	  done_smthg, undos
    in
    let done_smthg, undos = pop_commands false (Some 0) in
    if done_smthg then
      begin 
	(match undos with 
	   | None -> synchro () 
	   | Some n -> try Pfedit.undo n with _ -> synchro ());
	let start = if is_empty () then input_buffer#start_iter 
	else input_buffer#get_iter_at_mark (top ()).stop 
	in
	input_buffer#remove_tag_by_name 
	  ~start 
	  ~stop:(get_start_of_input ()) 
	  "processed";
	input_buffer#move_mark ~where:start (`NAME "start_of_input");
	input_buffer#place_cursor start;
	(try show_goals () with e -> ());
	clear_stdout ();
	clear_message ()
      end
  in
  let backtrack_to_insert () = backtrack_to (get_insert ()) in
  let undo_last_step () = 
    try
      let last_command = top () in
      let start = input_buffer#get_iter_at_mark last_command.start in
      let update_input () =
	input_buffer#remove_tag_by_name 
	  ~start
	  ~stop:(input_buffer#get_iter_at_mark last_command.stop) 
	  "processed";
	input_buffer#move_mark
	  ~where:start
	  (`NAME "start_of_input");
	input_buffer#place_cursor start;
	recenter_insert ();
	(try show_goals () with e -> ());
	clear_message ()
      in
      begin match last_command with 
	| {ast=_,VernacSolve _} -> 
	    begin 
	      try Pfedit.undo 1; ignore (pop ()); update_input () 
	      with _ -> backtrack_to start
	    end
	| {reset_info=Reset (id, {contents=true})} ->
	    ignore (pop ());
	    reset_to id;
	    update_input ()
	| { ast = _, ( VernacStartTheoremProof _ 
		     | VernacDefinition (_,_,ProveBody _,_,_)) } ->
	    ignore (pop ());
	    Pfedit.delete_current_proof ();
	    update_input ()
	| _ -> 
	    backtrack_to start
      end
    with
      | Size 0 -> !flash_info "Nothing to Undo"
  in
  let insert_command cp ip = 
    clear_message ();
    ignore (insert_this_phrase_on_success true false false cp ip) in
  let insert_commands l = 
    clear_message ();
    ignore (List.exists 
	      (fun (cp,ip) -> 
		 insert_this_phrase_on_success true false false cp ip) l)
  in
  let active_keypress_handler k = 
    match GdkEvent.Key.state k with
      | l when List.mem `MOD1 l ->
	  let k = GdkEvent.Key.keyval k in
	  if GdkKeysyms._Down=k 
	  then ignore (process_next_phrase true) 
	  else if GdkKeysyms._Right=k 
	  then process_until_insert_or_error () 
	  else if GdkKeysyms._Left=k 
	  then backtrack_to_insert ()
	  else if GdkKeysyms._r=k 
	  then ignore (reset_initial ())
	  else if GdkKeysyms._Up=k 
	  then ignore (undo_last_step ())
	  else if GdkKeysyms._Return=k
	  then ignore(
	    if (input_buffer#insert_interactive "\n") then
	      begin
		let i= (get_insert())#backward_word_start in
		input_buffer#place_cursor i;
		process_until_insert_or_error ()
	      end)
	  else if GdkKeysyms._a=k 
	  then insert_command "Progress Auto.\n" "Auto.\n"
	  else if GdkKeysyms._i=k 
	  then insert_command "Progress Intuition.\n" "Intuition.\n"
	  else if GdkKeysyms._t=k 
	  then insert_command "Progress Trivial.\n"  "Trivial.\n"
	  else if GdkKeysyms._o=k 
	  then insert_command "Omega.\n" "Omega.\n"
	  else if GdkKeysyms._s=k 
	  then insert_command "Progress Simpl.\n" "Simpl.\n"
	  else if GdkKeysyms._e=k 
	  then insert_command 
	    "Progress EAuto with *.\n" 
	    "EAuto with *.\n"
	  else if GdkKeysyms._asterisk=k 
	  then insert_command 
	    "Progress Auto with *.\n"
	    "Auto with *.\n"
	  else if GdkKeysyms._dollar=k 
	  then insert_commands 
	    ["Progress Trivial.\n","Trivial.\n";
	     "Progress Auto.\n","Auto.\n";
	     "Tauto.\n","Tauto.\n";
	     "Omega.\n","Omega.\n";
	     "Progress Auto with *.\n","Auto with *.\n";
	     "Progress EAuto with *.\n","EAuto with *.\n";
	     "Progress Intuition.\n","Intuition.\n";
	    ];
	  true
      | l when List.mem `CONTROL l -> 
	  let k = GdkEvent.Key.keyval k in
	  if GdkKeysyms._c=k
	  then break ();
	  false
      | l -> false
  in 
  let disconnected_keypress_handler k = 
    match GdkEvent.Key.state k with
      | l when List.mem `MOD1 l ->
	  let k = GdkEvent.Key.keyval k in
	  if (GdkKeysyms._Down=k || GdkKeysyms._Right=k
	      || GdkKeysyms._Left=k || GdkKeysyms._r=k
              ||  GdkKeysyms._Up=k)
	  then activate_input index;
	  true
      | l when List.mem `CONTROL l -> 
	  let k = GdkEvent.Key.keyval k in
	  if GdkKeysyms._c=k
	  then break ();
	  false
      | l -> false
  in 
  let deact_id = ref None in
  let act_id = ref None in
  let deactivate_function,activate_function = 
    (fun () -> 
       (match !act_id with None -> () 
	  | Some id ->
	      reset_initial ();
	      input_view#misc#disconnect id;
	      prerr_endline "DISCONNECTED old active : ";
	      print_id id;
       );
       deact_id := Some 
	 (input_view#event#connect#key_press disconnected_keypress_handler);
       prerr_endline "CONNECTED  inactive : ";
       print_id (out_some !deact_id)
    ),
    (fun () -> 
       (match !deact_id with None -> () 
	  | Some id -> input_view#misc#disconnect id;
	      prerr_endline "DISCONNECTED old inactive : ";
	      print_id id
       );
       act_id := Some 
	 (input_view#event#connect#key_press active_keypress_handler);
       prerr_endline "CONNECTED active : ";
       print_id (out_some !act_id);
       Sys.chdir (match (Vector.get input_views index).filename with
		       | None -> initial_cwd
		       | Some f -> Filename.dirname f
		 )
    )
  in
  let r = Vector.get input_views index in
  r.deactivate <- deactivate_function; r.activate <- activate_function;
  let electric_handler () = 
    input_buffer#connect#insert_text ~callback:
      (fun it x -> 
	 begin try
	   if !last_index then begin
	     last_array.(0)<-x;
	     if (last_array.(1) ^ last_array.(0) = ".\n") then raise Found
	   end else begin
	     last_array.(1)<-x;
	     if (last_array.(0) ^ last_array.(1) = ".\n") then raise Found
	   end
	 with Found -> 
	   begin
	     ignore (process_next_phrase true)
	   end;
	 end;
	 last_index := not !last_index;)
  in
  ()
and activate_input i = 
  (match !active_view with
     | None -> () 
     | Some n -> 
	 prerr_endline ("DEACT"^(string_of_int n));
	 let f = (Vector.get input_views n).deactivate in 
	 f()
  );
  let activate_function = (Vector.get input_views i).activate in
  prerr_endline ("ACT"^(string_of_int i));
  activate_function ();
  prerr_endline ("ACTIVATED"^(string_of_int i));
  set_active_view i

let create_input_tab filename =
  let b = GText.buffer () in 
  let tablabel = GMisc.label () in 
  let v_box = GPack.hbox ~homogeneous:false () in
  let image = GMisc.image ~packing:v_box#pack () in
  let label = GMisc.label ~text:filename ~packing:v_box#pack () in
  let fr1 = GBin.frame ~shadow_type:`ETCHED_OUT
	      ~packing:((notebook ())#append_page ~tab_label:v_box#coerce) () 
  in 
  let sw1 = GBin.scrolled_window
	      ~vpolicy:`AUTOMATIC 
	      ~hpolicy:`AUTOMATIC
	      ~packing:fr1#add () 
  in
  let tv1 = GText.view ~buffer:b ~packing:(sw1#add) () in
  tv1#misc#set_name "ScriptWindow";
  let _ = tv1#set_editable true in
  let _ = tv1#set_wrap_mode `CHAR in
  b#place_cursor ~where:(b#start_iter);
  ignore (tv1#event#connect#button_press ~callback:
	    (fun ev -> GdkEvent.Button.button ev = 3));
  tv1#misc#grab_focus ();
  ignore (tv1#buffer#create_mark 
	    ~name:"start_of_input" 
	    tv1#buffer#start_iter);
  ignore (tv1#buffer#create_tag 
	    ~name:"to_process" 
	    [`BACKGROUND "light blue" ;`EDITABLE false]);
  ignore (tv1#buffer#create_tag 
	    ~name:"processed" 
	    [`BACKGROUND "light green" ;`EDITABLE false]);
  ignore (tv1#buffer#create_tag 
	    ~name:"error" 
	    [`UNDERLINE `DOUBLE ; `FOREGROUND "red"]);
  ignore (tv1#buffer#create_tag 
	    ~name:"kwd" 
	    [`FOREGROUND "blue"]);
  ignore (tv1#buffer#create_tag 
	    ~name:"decl" 
	    [`FOREGROUND "orange red"]);
  ignore (tv1#buffer#create_tag 
	    ~name:"comment" 
	    [`FOREGROUND "brown"]);
  ignore (tv1#buffer#create_tag 
	    ~name:"reserved" 
	    [`FOREGROUND "dark red"]);
  tv1
  
let main () = 
  let w = GWindow.window 
	    ~allow_grow:true ~allow_shrink:true 
	    ~width:window_width ~height:window_height 
	    ~title:"CoqIde" ()
  in
  let accel_group = GtkData.AccelGroup.create () in
  let vbox = GPack.vbox ~homogeneous:false ~packing:w#add () in
  let menubar = GMenu.menu_bar ~packing:vbox#pack () in
  let factory = new GMenu.factory menubar in
  let accel_group = factory#accel_group in

  (* File Menu *)
  let file_menu = factory#add_submenu "File" in
  let file_factory = new GMenu.factory file_menu ~accel_group in

  (* File/Load Menu *)
  let load_m = file_factory#add_item "Open" ~key:GdkKeysyms._O in
  let load_f () = 	  
    match GToolbox.select_file ~title:"Load file" () with 
      | None -> ()
      | Some f -> 
	  try
	    let b = Buffer.create 1024 in
	    with_file f ~f:(input_channel b);
	    let s = try_convert (Buffer.contents b) in
	    let view = create_input_tab (Filename.basename f) in
	    (match !manual_monospace_font with
	       | None -> ()
	       | Some n -> view#misc#modify_font n);
	    let index = add_input_view {view = view;
					activate = (fun () -> ());
					deactivate = (fun () -> ());
					filename = Some f
				       }
	    in
	    analyze_all index;
	    activate_input index;
	    let input_buffer = view#buffer in
	    input_buffer#set_text s;
	    input_buffer#place_cursor input_buffer#start_iter;
	    Highlight.highlight_all input_buffer;
	    input_buffer#set_modified false
	  with e -> !flash_info "Load failed"
  in
  ignore (load_m#connect#activate load_f);

  (* File/Save Menu *)
  let save_m = file_factory#add_item "Save" ~key:GdkKeysyms._S in
  let save_f () = 
    let current = get_current_view () in
    try (match current.filename with 
	   | None -> 
	       begin match GToolbox.select_file ~title:"Save file" ()
	       with
		 | None -> ()
		 | Some f -> 
		     try_export f (current.view#buffer#get_text ());
		     current.filename <- Some f;
		     set_current_tab_label (Filename.basename f);
		     current.view#buffer#set_modified false
	       end
	   | Some f -> 
	       try_export f (current.view#buffer#get_text ());
	       current.view#buffer#set_modified false);
      !flash_info "Saved"
    with e -> !flash_info "Save failed"
  in   
  ignore (save_m#connect#activate save_f);

  (* File/Save As Menu *)
  let saveas_m = file_factory#add_item "Save as" in
  let saveas_f () = 
    let current = get_current_view () in
    try (match current.filename with 
	   | None -> 
	       begin match GToolbox.select_file ~title:"Save file as" ()
	       with
		 | None -> ()
		 | Some f -> 
		     try_export f (current.view#buffer#get_text ());
		     current.filename <- Some f;
		     set_current_tab_label (Filename.basename f);
		     current.view#buffer#set_modified false
	       end
	   | Some f -> 
	       begin match GToolbox.select_file 
		 ~dir:(ref (Filename.dirname f)) 
		 ~filename:(Filename.basename f)
		 ~title:"Save file as" ()
	       with
		 | None -> ()
		 | Some f -> 
		     try_export f (current.view#buffer#get_text ());
		     current.filename <- Some f;
		     set_current_tab_label (Filename.basename f);
		     current.view#buffer#set_modified false
	       end);
      !flash_info "Saved"
    with e -> !flash_info "Save failed"
  in   
  ignore (saveas_m#connect#activate saveas_f);
  
  
  (* File/Save All Menu *)
  let saveall_m = file_factory#add_item "Save All" in
  let saveall_f () = 
    Vector.iter 
      (fun {view = view ; filename = filename} -> 
	 match filename with 
	   | None -> ()
	   | Some f ->
	       try_export f (view#buffer#get_text ());
	       view#buffer#set_modified false
      )  input_views
  in
  let has_something_to_save () = 
    Vector.exists
      (fun {view=view} -> view#buffer#modified)
      input_views
  in
  ignore (saveall_m#connect#activate saveall_f);

  (* File/Revert Menu *)
  let revert_m = file_factory#add_item "Revert" in
  revert_m#misc#set_state `INSENSITIVE;

  (* File/Print Menu *)
  let print_m = file_factory#add_item "Print" in
  print_m#misc#set_state `INSENSITIVE;

  (* File/Export to Menu *)
  let file_export_m =  file_factory#add_submenu "Export to" in

  let file_export_factory = new GMenu.factory file_export_m ~accel_group in
  let export_html_m = file_export_factory#add_item "Html" in
  export_html_m#misc#set_state `INSENSITIVE;
  
  let export_latex_m = file_export_factory#add_item "LaTeX" in
  export_latex_m#misc#set_state `INSENSITIVE;

  let export_dvi_m = file_export_factory#add_item "Dvi" in
  export_dvi_m#misc#set_state `INSENSITIVE;

  let export_ps_m = file_export_factory#add_item "Ps" in
  export_ps_m#misc#set_state `INSENSITIVE;

  (* File/Rehighlight Menu *)
  let rehighlight_m = file_factory#add_item "Rehighlight" ~key:GdkKeysyms._L in
  ignore (rehighlight_m#connect#activate 
	    (fun () -> Highlight.highlight_all 
	       (get_current_view()).view#buffer));

  (* File/Refresh Menu *)
  let refresh_m = file_factory#add_item "Restart all" ~key:GdkKeysyms._R in
  refresh_m#misc#set_state `INSENSITIVE;

  (* Fiel/Quit Menu *)
  let quit_f () =
    if has_something_to_save () then 
      match (GToolbox.question_box ~title:"Quit"
	       ~buttons:["Save Named Buffers and Quit";
			 "Don't Save and Quit";
			 "Don't Quit"] 
	       ~default:0
	       ~icon:
	       (let img = GMisc.image () in
		img#set_stock "gtk-dialog-warning" ~size:6;
		img#coerce)
	       "There are unsaved buffers"
	    )
      with 1 -> saveall_f () ; exit 0
	| 2 -> exit 0
	| _ -> ()
    else exit 0
  in
  let quit_m = file_factory#add_item "Quit" ~key:GdkKeysyms._Q ~callback:quit_f
  in
  ignore (w#event#connect#delete (fun _ -> quit_f (); true));

  (* Navigation Menu *)
  let navigation_menu =  factory#add_submenu "Navigation" in
  let navigation_factory = new GMenu.factory navigation_menu ~accel_group in
  ignore (navigation_factory#add_item "Forward");
  ignore (navigation_factory#add_item "Backward");
  ignore (navigation_factory#add_item "Forward to");
  ignore (navigation_factory#add_item "Backward to");
  ignore (navigation_factory#add_item "Start");
  ignore (navigation_factory#add_item "End");

  (* Tactics Menu *)
  let tactics_menu =  factory#add_submenu "Tactics" in
  let tactics_factory = new GMenu.factory tactics_menu ~accel_group in
  ignore (tactics_factory#add_item "Auto");
  ignore (tactics_factory#add_item "Auto with *");
  ignore (tactics_factory#add_item "EAuto");
  ignore (tactics_factory#add_item "EAuto with *");
  ignore (tactics_factory#add_item "Intuition");
  ignore (tactics_factory#add_item "Omega");
  ignore (tactics_factory#add_item "Simpl");
  ignore (tactics_factory#add_item "Tauto");
  ignore (tactics_factory#add_item "Trivial");
  
  (* Templates Menu *)
  let templates_menu =  factory#add_submenu "Templates" in
  let templates_factory = new GMenu.factory templates_menu ~accel_group ~accel_modi:[`MOD1] in
  let templates_tactics = templates_factory#add_submenu "Tactics" in
  let templates_tactics_factory = new GMenu.factory templates_tactics ~accel_group in
  ignore (templates_tactics_factory#add_item "Auto");
  ignore (templates_tactics_factory#add_item "Auto with *");
  ignore (templates_tactics_factory#add_item "EAuto");
  ignore (templates_tactics_factory#add_item "EAuto with *");
  ignore (templates_tactics_factory#add_item "Intuition");
  ignore (templates_tactics_factory#add_item "Omega");
  ignore (templates_tactics_factory#add_item "Simpl");
  ignore (templates_tactics_factory#add_item "Tauto");
  ignore (templates_tactics_factory#add_item "Trivial");
  let templates_commands = templates_factory#add_submenu "Commands" in
  let templates_commands_factory = new GMenu.factory templates_commands 
				     ~accel_group 
				     ~accel_modi:[`MOD1]
  in
  (* Templates/Commands/Lemma *)
  let callback () = 
    let {view = view } = get_current_view () in
    if (view#buffer#insert_interactive "Lemma new_lemma : .\nProof.\n\nSave.\n") then
      begin
	let iter = view#buffer#get_iter_at_mark `INSERT in
	ignore (iter#nocopy#backward_chars 19);
	view#buffer#move_mark `INSERT iter;
	ignore (iter#nocopy#backward_chars 9);
	view#buffer#move_mark `SEL_BOUND iter;
	Highlight.highlight_all view#buffer
      end
  in
  ignore (templates_commands_factory#add_item "Lemma _" ~callback ~key:GdkKeysyms._L);

  
  (* Commands Menu *)
  let commands_menu =  factory#add_submenu "Commands" in
  let commands_factory = new GMenu.factory commands_menu ~accel_group in
  ignore (commands_factory#add_item "Compile");
  ignore (commands_factory#add_item "Make");
  ignore (commands_factory#add_item "Make Makefile");

  (* Configuration Menu *)
  let configuration_menu = factory#add_submenu "Configuration" in
  let configuration_factory = new GMenu.factory configuration_menu ~accel_group
  in
  let customize_colors_m =
    configuration_factory#add_item "Customize colors"
      ~callback:(fun () -> !flash_info "Not implemented")
  in
  font_selector := 
  Some (GWindow.font_selection_dialog 
	  ~title:"Select font..."
	  ~modal:true ());
  let font_selector = out_some !font_selector in
  font_selector#selection#set_font_name default_monospace_font_name;
  font_selector#selection#set_preview_text 
    "Lemma Truth: (p:Prover) `p < Coq`. Proof. Auto with *. Save."; 
  let customize_fonts_m = 
    configuration_factory#add_item "Customize fonts"
      ~callback:(fun () -> font_selector#present ())
  in
  let hb = GPack.paned `HORIZONTAL  ~border_width:3 ~packing:vbox#add () in
  let _ = hb#set_position (window_width*6/10 ) in
  _notebook := Some (GPack.notebook ~packing:hb#add1 ());
  let nb = notebook () in
  let fr2 = GBin.frame ~shadow_type:`ETCHED_OUT ~packing:hb#add2 () in 
  let hb2 = GPack.paned `VERTICAL  ~border_width:3 ~packing:fr2#add () in
  hb2#set_position (window_height*7/10);
  let sw2 = GBin.scrolled_window 
	      ~vpolicy:`AUTOMATIC 
	      ~hpolicy:`AUTOMATIC
	      ~packing:(hb2#add) () in
  let sw3 = GBin.scrolled_window 
	      ~vpolicy:`AUTOMATIC 
	      ~hpolicy:`AUTOMATIC
	      ~packing:(hb2#add) () in
  let status_bar = GMisc.statusbar ~packing:vbox#pack () in
  let status_context = status_bar#new_context "Messages" in
  ignore (status_context#push "Ready");
  status := Some status_bar;
  push_info := (fun s -> ignore (status_context#push s));
  pop_info := (fun () -> status_context#pop ());
  flash_info := (fun s -> status_context#flash ~delay:5000 s);
  let tv2 = GText.view ~packing:(sw2#add) () in
  tv2#misc#set_name "GoalWindow";
  let _ = tv2#set_editable false in
  let tb2 = tv2#buffer in
  let tv3 = GText.view ~packing:(sw3#add) () in
  tv2#misc#set_name "MessageWindow";
  let _ = tv2#set_wrap_mode `CHAR in
  let _ = tv3#set_wrap_mode `WORD in
  let _ = tv3#set_editable false in
  let _ = GtkBase.Widget.add_events tv2#as_widget [`POINTER_MOTION] in
  let _ = tv2#event#connect#motion_notify
	    ~callback:(fun e -> 
			 let win = match tv2#get_window `WIDGET with
			   | None -> assert false
			   | Some w -> w
			 in
			 let x,y = Gdk.Window.get_pointer_location win in
			 let b_x,b_y = tv2#window_to_buffer_coords 
					 ~tag:`WIDGET 
					 ~x 
					 ~y 
			 in
			 let it = tv2#get_iter_at_location ~x:b_x ~y:b_y in
			 let tags = it#tags in
			 List.iter 
			   ( fun t ->
			       ignore (GtkText.Tag.event 
					 t#as_tag
					 tv2#as_widget
					 e 
					 it#as_textiter))
			   tags;
			 false)
  in
  ignore (font_selector#cancel_button#connect#released 
	    ~callback:font_selector#misc#hide);
  ignore (font_selector#ok_button#connect#released 
	    ~callback:(fun () -> 
			 (match font_selector#selection#font_name with
			    | None -> ()
			    | Some n -> 
				let pango_font = Pango.Font.from_string n in
				tv2#misc#modify_font pango_font;
				tv3#misc#modify_font pango_font;
				Vector.iter 
				  (fun {view=view} -> view#misc#modify_font pango_font)
				  input_views;
				manual_monospace_font := Some pango_font
			 );
			 font_selector#misc#hide ()));

  (try 
     let startup_image = GdkPixbuf.from_file "coq.gif" in
     tv2#buffer#insert_pixbuf ~iter:tv2#buffer#start_iter 
       ~pixbuf:startup_image;
     tv2#buffer#insert ~iter:tv2#buffer#start_iter "\t\t";
   with _ -> ());
  tv2#buffer#insert "\nCoqIde: an experimental Gtk2 interface for Coq.\n";
  tv2#buffer#insert (try_convert (Coq.version ()));
  w#add_accel_group accel_group;
  (* Remove default pango menu for textviews *)
  ignore (tv2#event#connect#button_press ~callback:
	    (fun ev -> GdkEvent.Button.button ev = 3));
  ignore (tv3#event#connect#button_press ~callback:
	    (fun ev -> GdkEvent.Button.button ev = 3));
  tv2#misc#set_can_focus false;
  tv3#misc#set_can_focus false;
  ignore (tv2#buffer#create_mark 
	    ~name:"end_of_conclusion" 
	    tv2#buffer#start_iter);
  ignore (tv3#buffer#create_tag 
	    ~name:"error" 
	    [`FOREGROUND "red"]);
  w#show ();
  message_view := Some tv3;
  proof_view := Some tv2;
  let view = create_input_tab "New File" in
  let index = add_input_view {view = view;
			      activate = (fun () -> ());
			      deactivate = (fun () -> ());
			      filename = None}
  in
  analyze_all index;
  activate_input index;
  set_tab_image index yes_icon;

  (match !manual_monospace_font with 
     | None -> ()
     | Some f -> view#misc#modify_font f; tv2#misc#modify_font f; tv3#misc#modify_font f)
    
let start () = 
  cant_break ();
  Coq.init ();
  GtkMain.Rc.add_default_file ".coqiderc";
  (try 
     GtkMain.Rc.add_default_file (Filename.concat (Sys.getenv "HOME") ".coqiderc");
  with Not_found -> ());
  ignore (GtkMain.Main.init ());
  Glib.Message.set_log_handler ~domain:"Gtk" ~levels:[`ERROR;`FLAG_FATAL;
						      `WARNING;`CRITICAL]
    (fun ~level msg ->
         failwith ("Coqide internal error: " ^ msg)
    );
  main ();
  Sys.catch_break true;
  while true do 
    try 
      GMain.Main.main ()
    with 
      | Sys.Break -> prerr_endline "Interrupted." ; flush stderr
      | e -> 
	  prerr_endline ("CoqIde fatal error:" ^ (Printexc.to_string e));
	  crash_save 127
  done
