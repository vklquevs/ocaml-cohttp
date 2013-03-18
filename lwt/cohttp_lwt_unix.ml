(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

let check_debug norm_fn debug_fn =
  try
    ignore(Sys.getenv "COHTTP_DEBUG");
    debug_fn
  with Not_found ->
    norm_fn
    
module IO = struct

  type 'a t = 'a Lwt.t
  let (>>=) = Lwt.bind
  let return = Lwt.return

  type ic = Lwt_io.input_channel
  type oc = Lwt_io.output_channel

  let iter fn x = Lwt_list.iter_s fn x

  let read_line =
    check_debug
      (fun ic -> Lwt_io.read_line_opt ic)
      (fun ic ->
        match_lwt Lwt_io.read_line_opt ic with
        |None as x -> Printf.eprintf "%4d <<< EOF\n" (Unix.getpid ()); return x
        |Some l as x -> Printf.eprintf "%4d <<< %s\n" (Unix.getpid ()) l; return x)

  let read =
   check_debug
     (fun ic count ->
       try_lwt Lwt_io.read ~count ic
       with End_of_file -> return "")
     (fun ic count ->
       lwt buf = 
         try_lwt Lwt_io.read ~count ic
         with End_of_file -> return "" in
       Printf.eprintf "%4d <<<[%d] %s" (Unix.getpid ()) count buf;
       return buf)

  let read_exactly =
    check_debug
      (fun ic len ->
        let buf = String.create len in
        try_lwt Lwt_io.read_into_exactly ic buf 0 len >> return (Some buf)
        with End_of_file -> return None)
     (fun ic len ->
        let buf = String.create len in
        lwt rd =
          try_lwt Lwt_io.read_into_exactly ic buf 0 len >> return (Some buf)
          with End_of_file -> return None in
        (match rd with
        |Some buf -> Printf.eprintf "%4d <<< %S" (Unix.getpid ()) buf
        |None -> Printf.eprintf "%4d <<< <EOF>\n" (Unix.getpid ()));
        return rd)

  let write =
    check_debug
      (fun oc buf -> Lwt_io.write oc buf)
      (fun oc buf -> Printf.eprintf "%4d >>> %s" (Unix.getpid ()) buf; Lwt_io.write oc buf)

  let write_line =
    check_debug
      (fun oc buf -> Lwt_io.write_line oc buf)
      (fun oc buf -> Printf.eprintf "%4d >>> %s\n" (Unix.getpid ()) buf; Lwt_io.write_line oc buf)
end

module Request = Cohttp.Request.Make(IO)
module Response = Cohttp.Response.Make(IO)


module Client = struct
  open Lwt
  include Cohttp.Client.Make(IO)(Request)(Response)
 
  let call ?headers ?(chunked=false) ?body meth uri =
    let mvar = Lwt_mvar.create_empty () in
    let state = ref `Waiting_for_response in
    let signal_handler s =
      match !state, s with
      |`Waiting_for_response, `Response resp ->
         let body, push_body = Lwt_stream.create () in
         state := `Getting_body push_body;
         Lwt_mvar.put mvar (resp, body)
      |`Getting_body push_body, `Body buf ->
         push_body (Some buf); (* TODO: Alas, no flow control here *)
         return ()
      |`Getting_body push_body, `Body_end ->
         state := `Complete;
         push_body None;
         return ();
      |`Waiting_for_response, (`Body _|`Body_end)
      |_, `Failure
      |`Getting_body _, `Response _ ->
         (* TODO warning and non-fatal ? *)
         assert false
      |`Complete, _ -> return ()
    in
    return ()
end

(*
module Server = struct
  open Lwt
  include Cohttp_lwt.Server(Request)(Response)(Net)

  let blank_uri = Uri.of_string "" 

  let resolve_file ~docroot ~uri =
    (* This normalises the Uri and strips out .. characters *)
    let frag = Uri.path (Uri.resolve "" blank_uri uri) in
    Filename.concat docroot frag

  exception Isnt_a_file
  let respond_file ?headers ~fname () =
    try_lwt
      (* Check this isnt a directory first *)
      lwt () = wrap (fun () -> 
       if Unix.((stat fname).st_kind <> S_REG) then raise Isnt_a_file) in
      lwt ic = Lwt_io.open_file ~buffer_size:16384 ~mode:Lwt_io.input fname in
      lwt len = Lwt_io.length ic in
      let encoding = Cohttp.Transfer.Fixed (Int64.to_int len) in
      let count = 16384 in
      let stream = Lwt_stream.from (fun () ->
        try_lwt 
          Lwt_io.read ~count ic >|=
             function
             |"" -> None
             |buf -> Some buf
        with
         exn ->
           prerr_endline ("exn: " ^ (Printexc.to_string exn));
           return None
      ) in
      Lwt_stream.on_terminate stream (fun () -> 
        ignore_result (Lwt_io.close ic));
      let body = Body.body_of_stream stream in
      let res = Response.make ~status:`OK ~encoding ?headers () in
      return (res, body)
    with
     | Unix.Unix_error(Unix.ENOENT,_,_) | Isnt_a_file ->
         respond_not_found ()
     | exn ->
         let body = Printexc.to_string exn in
         respond_error ~status:`Internal_server_error ~body ()
end

let server ?timeout ~address ~port spec =
  lwt sockaddr = Net.build_sockaddr address port in
  Net.Tcp_server.init ~sockaddr ~timeout (Server.callback spec)
*)
