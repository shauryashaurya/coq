(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Number

val wit_number_string_mapping :
  (bool * Libnames.qualid * Libnames.qualid) Genarg.vernac_genarg_type

val number_string_mapping :
  (bool * Libnames.qualid * Libnames.qualid) Pcoq.Entry.t

val wit_number_string_via : number_string_via Genarg.vernac_genarg_type

val number_string_via : number_string_via Pcoq.Entry.t

val wit_number_modifier : Number.number_option Genarg.vernac_genarg_type

val number_modifier : Number.number_option Pcoq.Entry.t

val wit_number_options : Number.number_option list Genarg.vernac_genarg_type

val number_options :
  Number.number_option list Pcoq.Entry.t

val wit_string_option : number_string_via Genarg.vernac_genarg_type

val string_option : number_string_via Pcoq.Entry.t
