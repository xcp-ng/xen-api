(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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
(** A collection of extensions to the [Unix] module. *)

val _exit : int -> unit

val raise_with_preserved_backtrace : exn -> (unit -> unit) -> 'b
(** A wrapper that preserves the backtrace (otherwise erased by calling
    formatting functions, for example) *)

val unlink_safe : string -> unit

val mkdir_safe : string -> Unix.file_perm -> unit

val mkdir_rec : string -> Unix.file_perm -> unit

val rm_rec : ?rm_top:bool -> string -> unit
(** removes a file or recursively removes files/directories below a directory without following
    symbolic links. If path is a directory, it is only itself removed if rm_top is true. If path
    is non-existent nothing happens, it does not lead to an error. *)

val pidfile_write : string -> unit

val pidfile_read : string -> int option

val with_file :
     string
  -> Unix.open_flag list
  -> Unix.file_perm
  -> (Unix.file_descr -> 'a)
  -> 'a

val with_input_channel : string -> (in_channel -> 'a) -> 'a

val with_directory : string -> (Unix.dir_handle -> 'a) -> 'a

(** Exception to be raised in function to break out of [file_lines_fold]. *)
exception Break

val lines_fold : ('a -> string -> 'a) -> 'a -> in_channel -> 'a
(** Folds function [f] over every line in the input channel *)

val lines_iter : (string -> unit) -> in_channel -> unit
(** Applies function [f] to every line in the input channel *)

val file_lines_fold : ('a -> string -> 'a) -> 'a -> string -> 'a
(** Folds function [f] over every line in the file at [file_path] using the
    starting value [start]. *)

val read_lines : path:string -> string list
(** [read_lines path] returns a list of lines in the file at [path]. *)

val file_lines_iter : (string -> unit) -> string -> unit
(** Applies function [f] to every line in the file at [file_path]. *)

val fd_blocks_fold : int -> ('a -> bytes -> 'a) -> 'a -> Unix.file_descr -> 'a
(** [fd_blocks_fold block_size f start fd] folds [f] over blocks (strings)
    from the fd [fd] with initial value [start] *)

val readfile_line : (string -> 'a) -> string -> unit
(** Alias for function [file_lines_iter]. *)

val buffer_of_fd : Unix.file_descr -> Buffer.t
(** [buffer_of_fd fd] returns a Buffer.t containing all data read from [fd] up to EOF *)

val string_of_fd : Unix.file_descr -> string
(** [string_of_fd fd] returns a string containing all data read from [fd] up to EOF *)

val buffer_of_file : string -> Buffer.t
(** [buffer_of_file file] returns a Buffer.t containing the contents of [file] *)

val string_of_file : string -> string
(** [string_of_file file] returns a string containing the contents of [file] *)

val atomic_write_to_file :
  string -> Unix.file_perm -> (Unix.file_descr -> 'a) -> 'a
(** [atomic_write_to_file fname perms f] writes a file to path [fname]
    using the function [f] with permissions [perms]. In case of error during
    the operation the file with the path [fname] is not modified at all. *)

val write_string_to_file : ?perms:Unix.file_perm -> string -> string -> unit
(** [write_string_to_file fname contents] creates a file with path [fname]
    with the string [contents] as its contents, atomically *)

val write_bytes_to_file : ?perms:Unix.file_perm -> string -> bytes -> unit
(** [write_string_to_file fname contents] creates a file with path [fname]
    with the buffer [contents] as its contents, atomically *)

val execv_get_output : string -> string array -> int * Unix.file_descr

val copy_file : ?limit:int64 -> Unix.file_descr -> Unix.file_descr -> int64

val file_exists : string -> bool
(** Returns true if and only if a file exists at the given path. *)

val touch_file : string -> unit
(** Sets both the access and modification times of the file
 *  at the given path to the current time. Creates an empty
 *  file at the given path if no such file already exists.  *)

val is_empty_file : string -> bool
(** Returns true if and only if an empty file exists at the given path. *)

val delete_empty_file : string -> bool
(** Safely deletes a file at the given path if (and only if) the
 *  file exists and is empty. Returns true if a file was deleted. *)

exception Host_not_found of string

val open_connection_fd : string -> int -> Unix.file_descr

val open_connection_unix_fd : string -> Unix.file_descr

exception Process_still_alive

val kill_and_wait : ?signal:int -> ?timeout:float -> int -> unit

val proxy : Unix.file_descr -> Unix.file_descr -> unit

val really_read : Unix.file_descr -> bytes -> int -> int -> unit

val really_read_string : Unix.file_descr -> int -> string

val really_write : Unix.file_descr -> string -> int -> int -> unit
(** [really_write] keeps repeating the write operation until all bytes
 * have been written or an error occurs. This is not atomic but is
 * robust against EINTR errors.
 * See: https://ocaml.github.io/ocamlunix/ocamlunix.html#sec118 *)

val really_write_string : Unix.file_descr -> string -> unit

val try_read_string : ?limit:int -> Unix.file_descr -> string

exception Timeout

val with_socket_timeout : Unix.file_descr -> float option -> (unit -> 'a) -> 'a

val time_limited_write : Unix.file_descr -> int -> bytes -> float -> unit

val time_limited_write_substring :
  Unix.file_descr -> int -> string -> float -> unit

val time_limited_read : Unix.file_descr -> int -> float -> string

val time_limited_single_read :
  Unix.file_descr -> int -> max_wait:float -> string

val select :
     Unix.file_descr list
  -> Unix.file_descr list
  -> Unix.file_descr list
  -> float
  -> Unix.file_descr list * Unix.file_descr list * Unix.file_descr list

val read_data_in_string_chunks :
     (string -> int -> unit)
  -> ?block_size:int
  -> ?max_bytes:int
  -> Unix.file_descr
  -> int

val read_data_in_chunks :
     (bytes -> int -> unit)
  -> ?block_size:int
  -> ?max_bytes:int
  -> Unix.file_descr
  -> int

val spawnvp :
  ?pid_callback:(int -> unit) -> string -> string array -> Unix.process_status

val double_fork : (unit -> unit) -> unit

external set_tcp_nodelay : Unix.file_descr -> bool -> unit
  = "stub_unixext_set_tcp_nodelay"

external set_sock_keepalives : Unix.file_descr -> int -> int -> int -> unit
  = "stub_unixext_set_sock_keepalives"

external fsync : Unix.file_descr -> unit = "stub_unixext_fsync"

external get_max_fd : unit -> int = "stub_unixext_get_max_fd"

external blkgetsize64 : Unix.file_descr -> int64 = "stub_unixext_blkgetsize64"

val int_of_file_descr : Unix.file_descr -> int

val file_descr_of_int : int -> Unix.file_descr

val close_all_fds_except : Unix.file_descr list -> unit

val resolve_dot_and_dotdot : string -> string

val seek_to : Unix.file_descr -> int -> int

val seek_rel : Unix.file_descr -> int -> int

val current_cursor_pos : Unix.file_descr -> int

val wait_for_path : string -> (float -> unit) -> int -> unit

val send_fd :
     Unix.file_descr
  -> bytes
  -> int
  -> int
  -> Unix.msg_flag list
  -> Unix.file_descr
  -> int

val send_fd_substring :
     Unix.file_descr
  -> string
  -> int
  -> int
  -> Unix.msg_flag list
  -> Unix.file_descr
  -> int

val recv_fd :
     Unix.file_descr
  -> bytes
  -> int
  -> int
  -> Unix.msg_flag list
  -> int * Unix.sockaddr * Unix.file_descr

type statvfs_t = {
    f_bsize: int64
  ; f_frsize: int64
  ; f_blocks: int64
  ; f_bfree: int64
  ; f_bavail: int64
  ; f_files: int64
  ; f_ffree: int64
  ; f_favail: int64
  ; f_fsid: int64
  ; f_flag: int64
  ; f_namemax: int64
}

val statvfs : string -> statvfs_t

val domain_of_addr : string -> Unix.socket_domain option
(** Returns Some Unix.PF_INET or Some Unix.PF_INET6 if passed a valid IP address, otherwise returns None. *)

val test_open : int -> unit
(** [test_open n] opens n file descriptors. This is useful for testing that the application makes no calls
  to [Xapi_stdext_unix.Unixext.select] that use file descriptors, because such calls will then immediately fail.

  This assumes that [ulimit -n] has been suitably increased in the test environment.

  Can only be called once in a program, and will raise an exception otherwise.

  The file descriptors will stay open until the program exits.
 *)

module Daemon : sig
  (** OCaml interface to libsystemd.

      Standalone reimplementation of parts of `ocaml-systemd` and `libsystemd` to
      avoid linking libsystemd and its dependencies. Follows similar changes
      in the hypervisor in 78510f3a1522f2856330ffa429e0e35f8aab4277
      and caf864482689a5dd6a945759b6372bb260d49665 *)
  module State : sig
    type t =
      | Ready
          (** Tells the service manager that service startup is finished,
              or the service finished loading its configuration.
              Since there is little value in signaling non-readiness, the only value
              services should send is "READY=1" (i.e. "READY=0" is not defined). *)
      | Reloading
        (* Tells the service manager that the service is reloading its configuration. *)
      | Stopping
        (* Tells the service manager that the service is beginning its shutdown. *)
      | Status of string
        (* Passes a single-line UTF-8 status string back to the service
           manager that describes the service state. *)
      | Error of Unix.error
        (* If a service fails, the errno-style error code, formatted as string. *)
      | Buserror of string
        (* If a service fails, the D-Bus error-style error code. *)
      | MainPID of int
        (* The main process ID (PID) of the service, in case the service
           manager did not fork off the process itself. *)
      | Watchdog
    (* Tells the service manager to update the watchdog timestamp. *)
  end

  val systemd_notify : State.t -> bool
  (** [systemd_notify state] informs systemd about changed
      daemon state.
      If the notification was sent successfully, returns true.
      Otherwise returns false.

      See sd_notify(3) for more information *)

  val systemd_booted : unit -> bool
  (** [systemd_booted] returns true if the system was booted with systemd,
      and false otherwise.

      See sd_booted(3) for more information. *)
end
