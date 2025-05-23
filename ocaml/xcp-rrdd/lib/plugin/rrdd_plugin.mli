(*
 * Copyright (C) 2013 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(** Library to simplify writing an rrdd plugin. *)

(** Asynchronous interface to create, cancel and query the state of stats
    reporting threads. *)
module Reporter : sig
  (** The state of a reporter. *)
  type state =
    | Running  (** The reporter is running. *)
    | Cancelled  (** A thread has cancelled the reporter. *)
    | Stopped of [`New | `Cancelled | `Failed of exn]
        (** The reporter has stopped. *)

  (** Specify how the data we are collecting will be reported. *)
  type target =
    | Local of int
        (** [Local pages] Specifies that we will be reporting data to an rrdd
        				process in the same domain as this process, and we will be sharing
        				[pages] with this process. *)

  (** Abstract type of stats reporters. *)
  type t

  val start :
       (module Debug.DEBUG)
    -> uid:string
    -> neg_shift:float
    -> target:target
    -> protocol:Rrd_interface.plugin_protocol
    -> dss_f:(unit -> (Rrd.ds_owner * Ds.ds) list)
    -> unit
  (** Create a synchronous stats reporter. This function will block forever
      	    unless it catches a Sys.Break. It will usually be simpler to call
      	    Process.initialise followed by Process.main_loop rather than calling this
      	    function directly.
      	    {ul
      	    {- [uid] is the UID which will be registered with rrdd.}
      	    {- [neg_shift] is the amount of time before rrdd collects data that we
      	       should report our data.}
      	    {- [target] specifies the transport via which data will be reported to
      	       rrdd.}
      	    {- [protocol] specifies the protocol used to transmit the data.}
      	    {- [dss_f ()] will generate the list of datasources to be reported.}} *)

  val start_async :
       (module Debug.DEBUG)
    -> uid:string
    -> neg_shift:float
    -> target:target
    -> protocol:Rrd_interface.plugin_protocol
    -> dss_f:(unit -> (Rrd.ds_owner * Ds.ds) list)
    -> t
  (** Create an asynchronous stats reporter. Return a Reporter.t, which can be
      	    used to query the state of the reporter, or to cancel it.
      	    {ul
      	    {- [uid] is the UID which will be registered with rrdd.}
      	    {- [neg_shift] is the amount of time before rrdd collects data that we
      	       should report our data.}
      	    {- [target] specifies the transport via which data will be reported to
      	       rrdd.}
      	    {- [protocol] specifies the protocol used to transmit the data.}
      	    {- [dss_f ()] will generate the list of datasources to be reported.}} *)

  val get_state : reporter:t -> state
  (** Query the state of a reporter. *)

  val cancel : reporter:t -> unit
  (** Signal to a reporter that we want it to cancel, and block until it has
      	    cleaned up and marked itself as Stopped. *)

  val wait_until_stopped : reporter:t -> unit
  (** Block until the reporter has marked itself stopped. *)
end

(** Functions useful for writing a single-purpose rrdd plugin daemon. *)
module Process : functor
  (_ : sig
     val name : string
   end)
  -> sig
  module D : Debug.DEBUG

  val initialise : unit -> unit
  (** Utility function for daemons whose sole purpose is to report data to rrdd.
      	    This will set up signal handlers, as well as daemonising and writing a pid
      	    file if specified on the CLI.

      	    Processes which need to use initialise should call it before spawning any
      	    threads.

      	    Processes which have tasks beyond reporting data to rrdd should probably
      	    not call this function. *)

  val main_loop :
       neg_shift:float
    -> target:Reporter.target
    -> protocol:Rrd_interface.plugin_protocol
    -> dss_f:(unit -> (Rrd.ds_owner * Ds.ds) list)
    -> unit
  (** Begin the main loop.
        	    {ul
        	    {- [neg_shift] is the amount of time before rrdd collects data that we
        	       should report our data.}
        	    {- [target] specifies the transport via which data will be reported to
        	       rrdd.}
        	    {- [protocol] specifies the protocol used to transmit the data.}
        	    {- [dss_f ()] will generate the list of datasources to be reported.}} *)
end
