
let get_insert input_buffer = input_buffer#get_iter_at_mark `INSERT

let is_char_start c = let code = Char.code c in code < 0x80 || code >= 0xc0

let byte_offset_to_char_offset s byte_offset = 
  assert (byte_offset < String.length s);
  let count_delta = ref 0 in
  for i = 0 to byte_offset do
    let code = Char.code s.[i] in
    if code >= 0x80 && code < 0xc0 then incr count_delta
  done;
  byte_offset - !count_delta


let process_pending () = 
  while Glib.Main.pending () do 
    ignore (Glib.Main.iteration false) 
  done

let debug = ref false

let prerr_endline s =
  if !debug then  prerr_endline s else ()

let print_id id =
  prerr_endline ("GOT sig id :"^(string_of_int (Obj.magic id)))

let try_convert s = 
  try
    if Glib.Utf8.validate s then s else
      (prerr_endline 
	 "Coqide warning: input is not UTF-8 encoded. Trying to convert from locale.";
       Glib.Convert.locale_to_utf8 s)
  with _ -> 
    "(* Fatal error: wrong encoding in input.
Please set your locale according to your file encoding.*)"

let try_export file_name s = 
  try 
    let s = Glib.Convert.locale_from_utf8 s in
    let oc = open_out file_name in
    output_string oc s;
    close_out oc
  with e -> prerr_endline (Printexc.to_string e)
