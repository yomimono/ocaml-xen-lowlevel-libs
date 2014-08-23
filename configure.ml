let config_mk = "config.mk"
let config_h = "config.h"

(* Configure script *)
open Cmdliner

let info =
  let doc = "Configures a package" in
  Term.info "configure" ~version:"0.1" ~doc 

let output_file filename lines =
  let oc = open_out filename in
  let lines = List.map (fun line -> line ^ "\n") lines in
  List.iter (output_string oc) lines;
  close_out oc

let cc verbose c_program =
  let c_file = Filename.temp_file "configure" ".c" in
  let o_file = c_file ^ ".o" in
  output_file c_file c_program;
  let found = Sys.command (Printf.sprintf "cc -c %s -o %s %s" c_file o_file (if verbose then "" else "2>/dev/null")) = 0 in
  if Sys.file_exists c_file then Sys.remove c_file;
  if Sys.file_exists o_file then Sys.remove o_file;
  found

let run verbose cmd =
  if verbose then Printf.printf "running: %s\n" cmd;
  let out_file = Filename.temp_file "configure" ".stdout" in
  let code = Sys.command (Printf.sprintf "%s > %s" cmd out_file) in
  let ic = open_in out_file in
  let result = ref [] in
  let lines =
    try
      while true do
        let line = input_line ic in
        result := line :: !result
      done;
      !result
    with End_of_file -> !result in
  close_in ic;
  if code <> 0
  then failwith (Printf.sprintf "%s: %d: %s" cmd code (String.concat " " (List.rev lines)))
  else List.rev lines

let find_header verbose name =
  let c_program = [
    Printf.sprintf "#include <%s>" name;
    "int main(int argc, const char *argv){";
    "return 0;";
    "}";
  ] in
  let found = cc verbose c_program in
  Printf.printf "Looking for %s: %s\n" name (if found then "ok" else "missing");
  found

let find_define verbose name =
  let c_program = [
    "#include <xenctrl.h>";
    "int main(int argc, const char *argv){";
    Printf.sprintf "int i = %s;" name;
    "return 0;";
    "}";
  ] in
  let found = cc verbose c_program in
  Printf.printf "Looking for %s: %s\n" name (if found then "ok" else "missing");
  found

let find_struct_member verbose structure member =
  let c_program = [
    "#include <stdlib.h>";
    "#include <libxl.h>";
    "#include <xenctrl.h>";
    "#include <xenguest.h>";
    Printf.sprintf "void test(%s *s) {" structure;
    Printf.sprintf "  int r = s->%s;\n" member;
    "}";
    "int main(int argc, const char *argv){";
    "  return 0;";
    "}";
  ] in
  let found = cc verbose c_program in
  Printf.printf "Looking for %s.%s: %s\n" structure member (if found then "ok" else "missing");
  found

let find_xenlight verbose = find_struct_member verbose "libxl_physinfo" "outstanding_pages"

let find_xen_4_4 verbose =
  let c_program = [
    "#include <stdlib.h>";
    "#include <xenctrl.h>";
    "#include <xenguest.h>";
    "int main(int argc, const char *argv){";
    "  int r = xc_domain_restore(NULL, 0, 0,";
    "          0, 0, 0,";
    "          0, 0, 0,";
    "          0, 0, /* int superpages */ 0,";
    "          /* int no_incr_generation_id */ 0,";
    "          /* int checkpointed_stream */0,";
    "          /* unsigned long *vm_generationid_addr */NULL,";
    "          NULL);";
    "  return 0;";
    "}";
  ] in
  let found = cc verbose c_program in
  Printf.printf "Looking for xen-4.4: %s\n" (if found then "ok" else "missing");
  found

let find_xen_4_5 verbose =
  let c_program = [
    "#include <stdlib.h>";
    "#include <xenctrl.h>";
    "#include <xenguest.h>";
    "int main(int argc, const char *argv){";
    "  int r = xc_vcpu_getaffinity(NULL, 0,";
    "                              0, NULL, NULL, 0);";
    "  return 0;";
    "}";
  ] in
  let found = cc verbose c_program in
  Printf.printf "Looking for xen-4.5: %s\n" (if found then "ok" else "missing");
  found

let check_arm_header verbose =
  let lines = run verbose "arch" in
  let arch = List.hd lines in
  let arm = String.length arch >= 3 && String.sub arch 0 3 = "arm" in
  if arm then begin
    let header = "/usr/include/xen/arch-arm/hvm/save.h" in
    if not(Sys.file_exists header) then begin
      Printf.printf "Creating empty header %s\n" header;
      ignore(run verbose (Printf.sprintf "mkdir -p %s" (Filename.dirname header)));
      ignore(run verbose (Printf.sprintf "touch %s" header))
    end
  end

let disable_xenctrl =
  let doc = "Disable the xenctrl library" in
  Arg.(value & flag & info ["disable-xenctrl"] ~docv:"DISABLE_XENCTRL" ~doc)

let disable_xenlight =
  let doc = "Disable the xenlight library" in
  Arg.(value & flag & info ["disable-xenlight"] ~docv:"DISABLE_XENLIGHT" ~doc)

let configure verbose disable_xenctrl disable_xenlight =
  check_arm_header verbose;
  let xenctrl  = find_header verbose "xenctrl.h" in
  let xenlight = find_xenlight verbose in
  let xen_4_4  = find_xen_4_4 verbose in
  let xen_4_5  = find_xen_4_5 verbose in
  let have_viridian = find_define verbose "HVM_PARAM_VIRIDIAN" in
  if not xenctrl then begin
    Printf.fprintf stderr "Failure: we can't build anything without xenctrl.h\n";
    exit 1;
  end;
 
  (* Write config.mk *)
  let lines = 
    [ "# Warning - this file is autogenerated by the configure script";
      "# Do not edit";
      Printf.sprintf "ENABLE_XENLIGHT=--%s-xenlight" (if xenlight && not disable_xenlight then "enable" else "disable");
      Printf.sprintf "ENABLE_XENCTRL=--%s-xenctrl" (if disable_xenctrl then "disable" else "enable");
      Printf.sprintf "ENABLE_XENGUEST42=--%s-xenguest42" (if xen_4_4 || xen_4_5 then "disable" else "enable");
      Printf.sprintf "ENABLE_XENGUEST44=%s" (if xen_4_4 || xen_4_5 then "true" else "false");
      Printf.sprintf "HAVE_XEN_4_5=%s" (if xen_4_5 then "true" else "false");

    ] in
  output_file config_mk lines;
  (* Write config.h *)
  let lines =
    [ "/* Warning - this file is autogenerated by the configure script */";
      "/* Do not edit */";
      (if have_viridian then "" else "/* ") ^ "#define HAVE_HVM_PARAM_VIRIDIAN" ^ (if have_viridian then "" else " */");
      (if xen_4_5 then "" else "/* ") ^ "#define HAVE_XEN_4_5" ^ (if xen_4_5 then "" else " */");
    ] in
  output_file config_h lines;
  (try Unix.unlink ("lib/" ^ config_h) with _ -> ());
  Unix.symlink ("../" ^ config_h) ("lib/" ^ config_h)

let arg =
  let doc = "enable verbose printing" in
  Arg.(value & flag & info ["verbose"; "v"] ~doc)

let configure_t = Term.(pure configure $ arg $ disable_xenctrl $ disable_xenlight)

let () = 
  match 
    Term.eval (configure_t, info) 
  with
  | `Error _ -> exit 1 
  | _ -> exit 0
