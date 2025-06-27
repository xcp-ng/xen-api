(*
 * Copyright (C) 2011 Citrix Systems Inc.
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

module D = Debug.Make (struct let name = "storage_migrate" end)

open D

(** As SXM is such a long running process, we dedicate this to log important 
  milestones during the SXM process *)
module SXM = Debug.Make (struct
  let name = "SXM"
end)

module Listext = Xapi_stdext_std.Listext
open Xapi_stdext_pervasives.Pervasiveext
module Unixext = Xapi_stdext_unix.Unixext
open Xmlrpc_client
open Storage_interface
open Storage_task

module State = struct
  module Receive_state = struct
    type t = {
        sr: Sr.t
      ; dummy_vdi: Vdi.t
      ; leaf_vdi: Vdi.t
      ; leaf_dp: dp
      ; parent_vdi: Vdi.t
      ; remote_vdi: Vdi.t
      ; mirror_vm: Vm.t
    }
    [@@deriving rpcty]

    let rpc_of_t = Rpcmarshal.marshal t.Rpc.Types.ty

    let t_of_rpc x =
      match Rpcmarshal.unmarshal t.Rpc.Types.ty x with
      | Ok y ->
          y
      | Error (`Msg m) ->
          failwith (Printf.sprintf "Failed to unmarshal Receive_state.t: %s" m)
  end

  module Send_state = struct
    type remote_info = {
        dp: dp
      ; vdi: Vdi.t
      ; url: string
      ; verify_dest: bool [@default false]
    }
    [@@deriving rpcty]

    type tapdev = Tapctl.tapdev

    let typ_of_tapdev =
      Rpc.Types.(
        Abstract
          {
            aname= "tapdev"
          ; test_data= []
          ; rpc_of= Tapctl.rpc_of_tapdev
          ; of_rpc= (fun x -> Ok (Tapctl.tapdev_of_rpc x))
          }
      )

    type handle = Scheduler.handle

    let typ_of_handle =
      Rpc.Types.(
        Abstract
          {
            aname= "handle"
          ; test_data= []
          ; rpc_of= Scheduler.rpc_of_handle
          ; of_rpc= (fun x -> Ok (Scheduler.handle_of_rpc x))
          }
      )

    type t = {
        url: string
      ; dest_sr: Sr.t
      ; remote_info: remote_info option
      ; local_dp: dp
      ; tapdev: tapdev option
      ; mutable failed: bool
      ; mutable watchdog: handle option
    }
    [@@deriving rpcty]

    let rpc_of_t = Rpcmarshal.marshal t.Rpc.Types.ty

    let t_of_rpc x =
      match Rpcmarshal.unmarshal t.Rpc.Types.ty x with
      | Ok y ->
          y
      | Error (`Msg m) ->
          failwith (Printf.sprintf "Failed to unmarshal Send_state.t: %s" m)
  end

  module Copy_state = struct
    type t = {
        base_dp: dp
      ; leaf_dp: dp
      ; remote_dp: dp
      ; dest_sr: Sr.t
      ; copy_vdi: Vdi.t
      ; remote_url: string
      ; verify_dest: bool [@default false]
    }
    [@@deriving rpcty]

    let rpc_of_t = Rpcmarshal.marshal t.Rpc.Types.ty

    let t_of_rpc x =
      match Rpcmarshal.unmarshal t.Rpc.Types.ty x with
      | Ok y ->
          y
      | Error (`Msg m) ->
          failwith (Printf.sprintf "Failed to unmarshal Copy_state.t: %s" m)
  end

  let loaded = ref false

  let mutex = Mutex.create ()

  type send_table = (string, Send_state.t) Hashtbl.t

  type recv_table = (string, Receive_state.t) Hashtbl.t

  type copy_table = (string, Copy_state.t) Hashtbl.t

  type osend

  type orecv

  type ocopy

  type _ operation =
    | Send_op : Send_state.t -> osend operation
    | Recv_op : Receive_state.t -> orecv operation
    | Copy_op : Copy_state.t -> ocopy operation

  type _ table =
    | Send_table : send_table -> osend table
    | Recv_table : recv_table -> orecv table
    | Copy_table : copy_table -> ocopy table

  let active_send : send_table = Hashtbl.create 10

  let active_recv : recv_table = Hashtbl.create 10

  let active_copy : copy_table = Hashtbl.create 10

  let table_of_op : type a. a operation -> a table = function
    | Send_op _ ->
        Send_table active_send
    | Recv_op _ ->
        Recv_table active_recv
    | Copy_op _ ->
        Copy_table active_copy

  let persist_root = ref "/var/run/nonpersistent"

  let path_of_table : type a. a table -> string = function
    | Send_table _ ->
        Filename.concat !persist_root "storage_mirrors_send.json"
    | Recv_table _ ->
        Filename.concat !persist_root "storage_mirrors_recv.json"
    | Copy_table _ ->
        Filename.concat !persist_root "storage_mirrors_copy.json"

  let rpc_of_table : type a. a table -> Rpc.t =
    let open Rpc_std_helpers in
    function
    | Send_table send_table ->
        rpc_of_hashtbl ~rpc_of:Send_state.rpc_of_t send_table
    | Recv_table recv_table ->
        rpc_of_hashtbl ~rpc_of:Receive_state.rpc_of_t recv_table
    | Copy_table copy_table ->
        rpc_of_hashtbl ~rpc_of:Copy_state.rpc_of_t copy_table

  let to_string : type a. a table -> string =
   fun table -> rpc_of_table table |> Jsonrpc.to_string

  let rpc_of_path path = Unixext.string_of_file path |> Jsonrpc.of_string

  let load_one : type a. a table -> unit =
   fun table ->
    let rpc = path_of_table table |> rpc_of_path in
    let open Rpc_std_helpers in
    match table with
    | Send_table table ->
        Hashtbl.iter (Hashtbl.replace table)
          (hashtbl_of_rpc ~of_rpc:Send_state.t_of_rpc rpc)
    | Recv_table table ->
        Hashtbl.iter (Hashtbl.replace table)
          (hashtbl_of_rpc ~of_rpc:Receive_state.t_of_rpc rpc)
    | Copy_table table ->
        Hashtbl.iter (Hashtbl.replace table)
          (hashtbl_of_rpc ~of_rpc:Copy_state.t_of_rpc rpc)

  let load () =
    ignore_exn (fun () -> load_one (Send_table active_send)) ;
    ignore_exn (fun () -> load_one (Recv_table active_recv)) ;
    ignore_exn (fun () -> load_one (Copy_table active_copy)) ;
    loaded := true

  let save_one : type a. a table -> unit =
   fun table ->
    to_string table |> Unixext.write_string_to_file (path_of_table table)

  let save () =
    Unixext.mkdir_rec !persist_root 0o700 ;
    save_one (Send_table active_send) ;
    save_one (Recv_table active_recv) ;
    save_one (Copy_table active_copy)

  let access_table ~save_after f table =
    Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
        if not !loaded then load () ;
        let result = f table in
        if save_after then save () ;
        result
    )

  let map_of () =
    let contents_of table =
      Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []
    in
    let send_ops = access_table ~save_after:false contents_of active_send in
    let recv_ops = access_table ~save_after:false contents_of active_recv in
    let copy_ops = access_table ~save_after:false contents_of active_copy in
    (send_ops, recv_ops, copy_ops)

  let add : type a. string -> a operation -> unit =
   fun id op ->
    let add' : type a. string -> a operation -> a table -> unit =
     fun id op table ->
      match (table, op) with
      | Send_table table, Send_op op ->
          Hashtbl.replace table id op
      | Recv_table table, Recv_op op ->
          Hashtbl.replace table id op
      | Copy_table table, Copy_op op ->
          Hashtbl.replace table id op
    in
    access_table ~save_after:true
      (fun table -> add' id op table)
      (table_of_op op)

  let find id table =
    access_table ~save_after:false
      (fun table -> Hashtbl.find_opt table id)
      table

  let remove id table =
    access_table ~save_after:true (fun table -> Hashtbl.remove table id) table

  let clear () =
    access_table ~save_after:true (fun table -> Hashtbl.clear table) active_send ;
    access_table ~save_after:true (fun table -> Hashtbl.clear table) active_recv ;
    access_table ~save_after:true (fun table -> Hashtbl.clear table) active_copy

  let remove_local_mirror id = remove id active_send

  let remove_receive_mirror id = remove id active_recv

  let remove_copy id = remove id active_copy

  let find_active_local_mirror id = find id active_send

  let find_active_receive_mirror id = find id active_recv

  let find_active_copy id = find id active_copy

  let mirror_id_of (sr, vdi) =
    Printf.sprintf "%s/%s"
      (Storage_interface.Sr.string_of sr)
      (Storage_interface.Vdi.string_of vdi)

  let of_mirror_id id =
    match String.split_on_char '/' id with
    | sr :: rest ->
        Storage_interface.
          (Sr.of_string sr, Vdi.of_string (String.concat "/" rest))
    | _ ->
        failwith "Bad id"

  let copy_id_of (sr, vdi) =
    Printf.sprintf "copy/%s/%s"
      (Storage_interface.Sr.string_of sr)
      (Storage_interface.Vdi.string_of vdi)

  let of_copy_id id =
    match String.split_on_char '/' id with
    | op :: sr :: rest when op = "copy" ->
        Storage_interface.
          (Sr.of_string sr, Vdi.of_string (String.concat "/" rest))
    | _ ->
        failwith "Bad id"
end

let vdi_info x =
  match x with
  | Some (Vdi_info v) ->
      v
  | _ ->
      failwith "Runtime type error: expecting Vdi_info"

module Local = StorageAPI (Idl.Exn.GenClient (struct
  let rpc call =
    Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"smapiv2"
      (Storage_utils.localhost_connection_args ())
      call
end))

let tapdisk_of_attach_info (backend : Storage_interface.backend) =
  let _, blockdevices, _, nbds =
    Storage_interface.implementations_of_backend backend
  in
  match (blockdevices, nbds) with
  | blockdevice :: _, _ -> (
      let path = blockdevice.Storage_interface.path in
      try
        match Tapctl.of_device (Tapctl.create ()) path with
        | tapdev, _, _ ->
            Some tapdev
      with
      | Tapctl.Not_blktap ->
          debug "Device %s is not controlled by blktap" path ;
          None
      | Tapctl.Not_a_device ->
          debug "%s is not a device" path ;
          None
      | _ ->
          debug "Device %s has an unknown driver" path ;
          None
    )
  | _, nbd :: _ -> (
    try
      let path, _ = Storage_interface.parse_nbd_uri nbd in
      let filename = Unix.realpath path |> Filename.basename in
      Scanf.sscanf filename "nbd%d.%d" (fun pid minor ->
          Some (Tapctl.tapdev_of ~pid ~minor)
      )
    with _ ->
      debug "No tapdisk found for NBD backend: %s" nbd.Storage_interface.uri ;
      None
  )
  | _ ->
      debug "No tapdisk found for backend: %s"
        (Storage_interface.(rpc_of backend) backend |> Rpc.to_string) ;
      None

let with_activated_disk ~dbg ~sr ~vdi ~dp ~vm f =
  let attached_vdi =
    Option.map
      (fun vdi ->
        let backend = Local.VDI.attach3 dbg dp sr vdi vm false in
        (vdi, backend)
      )
      vdi
  in
  finally
    (fun () ->
      let path_and_nbd =
        Option.map
          (fun (vdi, backend) ->
            let _xendisks, blockdevs, files, nbds =
              Storage_interface.implementations_of_backend backend
            in
            match (files, blockdevs, nbds) with
            | {path} :: _, _, _ | _, {path} :: _, _ ->
                Local.VDI.activate3 dbg dp sr vdi vm ;
                (path, false)
            | _, _, nbd :: _ ->
                Local.VDI.activate3 dbg dp sr vdi vm ;
                let unix_socket_path, export_name =
                  Storage_interface.parse_nbd_uri nbd
                in
                ( Attach_helpers.NbdClient.start_nbd_client ~unix_socket_path
                    ~export_name
                , true
                )
            | [], [], [] ->
                raise
                  (Storage_interface.Storage_error
                     (Backend_error
                        ( Api_errors.internal_error
                        , [
                            "No File, BlockDevice or Nbd implementation in \
                             Datapath.attach response: "
                            ^ (Storage_interface.(rpc_of backend) backend
                              |> Jsonrpc.to_string
                              )
                          ]
                        )
                     )
                  )
          )
          attached_vdi
      in
      finally
        (fun () -> f (Option.map (function path, _ -> path) path_and_nbd))
        (fun () ->
          Option.iter
            (function
              | path, true ->
                  Attach_helpers.NbdClient.stop_nbd_client ~nbd_device:path
              | _ ->
                  ()
              )
            path_and_nbd ;
          Option.iter (fun vdi -> Local.VDI.deactivate dbg dp sr vdi vm) vdi
        )
    )
    (fun () ->
      Option.iter
        (fun (vdi, _) -> Local.VDI.detach dbg dp sr vdi vm)
        attached_vdi
    )

let perform_cleanup_actions =
  List.iter (fun f ->
      try f ()
      with e ->
        error "Caught %s while performing cleanup actions" (Printexc.to_string e)
  )

let progress_callback start len t y =
  let new_progress = start +. (y *. len) in
  Storage_task.set_state t (Task.Pending new_progress) ;
  signal (Storage_task.id_of_handle t)

let remove_from_sm_config vdi_info key =
  {
    vdi_info with
    sm_config= List.filter (fun (k, _) -> k <> key) vdi_info.sm_config
  }

let add_to_sm_config vdi_info key value =
  let vdi_info = remove_from_sm_config vdi_info key in
  {vdi_info with sm_config= (key, value) :: vdi_info.sm_config}

(** This module [MigrateLocal] consists of the concrete implementations of the 
migration part of SMAPI. Functions inside this module are sender driven, which means
they tend to be executed on the sender side. although there is not a hard rule
on what is executed on the sender side, this provides some heuristics. *)
module MigrateLocal = struct
  (** [copy_into_vdi] is similar to [copy_into_sr] but requires a [dest_vdi] parameter *)
  let copy_into_vdi ~task ~dbg ~sr ~vdi ~vm ~url ~dest ~dest_vdi ~verify_dest =
    let remote_url = Storage_utils.connection_args_of_uri ~verify_dest url in
    let module Remote = StorageAPI (Idl.Exn.GenClient (struct
      let rpc =
        Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2" remote_url
    end)) in
    debug "copy local=%s/%s url=%s remote=%s/%s verify_dest=%B"
      (Storage_interface.Sr.string_of sr)
      (Storage_interface.Vdi.string_of vdi)
      url
      (Storage_interface.Sr.string_of dest)
      (Storage_interface.Vdi.string_of dest_vdi)
      verify_dest ;
    (* Check the remote SR exists *)
    let srs = Remote.SR.list dbg in
    if not (List.mem dest srs) then
      failwith
        (Printf.sprintf "Remote SR %s not found"
           (Storage_interface.Sr.string_of dest)
        ) ;
    let vdis = Remote.SR.scan dbg dest in
    let remote_vdi =
      try List.find (fun x -> x.vdi = dest_vdi) vdis
      with Not_found ->
        failwith
          (Printf.sprintf "Remote VDI %s not found"
             (Storage_interface.Vdi.string_of dest_vdi)
          )
    in
    let dest_content_id = remote_vdi.content_id in
    (* Find the local VDI *)
    let vdis = Local.SR.scan dbg sr in
    let local_vdi =
      try List.find (fun x -> x.vdi = vdi) vdis
      with Not_found ->
        failwith
          (Printf.sprintf "Local VDI %s not found"
             (Storage_interface.Vdi.string_of vdi)
          )
    in
    debug "copy local content_id=%s" local_vdi.content_id ;
    debug "copy remote content_id=%s" dest_content_id ;
    if local_vdi.virtual_size > remote_vdi.virtual_size then (
      (* This should never happen provided the higher-level logic is working properly *)
      error "copy local virtual_size=%Ld > remote virtual_size = %Ld"
        local_vdi.virtual_size remote_vdi.virtual_size ;
      failwith "local VDI is larger than the remote VDI"
    ) ;
    let on_fail : (unit -> unit) list ref = ref [] in
    let base_vdi =
      try
        let x =
          (List.find (fun x -> x.content_id = dest_content_id) vdis).vdi
        in
        debug
          "local VDI has content_id = %s; we will perform an incremental copy"
          dest_content_id ;
        Some x
      with _ ->
        debug "no local VDI has content_id = %s; we will perform a full copy"
          dest_content_id ;
        None
    in
    try
      let remote_dp = Uuidx.(to_string (make ())) in
      let base_dp = Uuidx.(to_string (make ())) in
      let leaf_dp = Uuidx.(to_string (make ())) in
      let dest_vdi_url =
        let url' = Http.Url.of_string url in
        Http.Url.set_uri url'
          (Printf.sprintf "%s/nbdproxy/%s/%s/%s/%s" (Http.Url.get_uri url')
             (Storage_interface.Vm.string_of vm)
             (Storage_interface.Sr.string_of dest)
             (Storage_interface.Vdi.string_of dest_vdi)
             remote_dp
          )
        |> Http.Url.to_string
      in
      debug "%s copy remote NBD URL = %s" __FUNCTION__ dest_vdi_url ;
      let id = State.copy_id_of (sr, vdi) in
      debug "Persisting state for copy (id=%s)" id ;
      State.add id
        State.(
          Copy_op
            Copy_state.
              {
                base_dp
              ; leaf_dp
              ; remote_dp
              ; dest_sr= dest
              ; copy_vdi= remote_vdi.vdi
              ; remote_url= url
              ; verify_dest
              }
        ) ;
      SXM.info "%s: copy initiated local_vdi:%s dest_vdi:%s" __FUNCTION__
        (Storage_interface.Vdi.string_of vdi)
        (Storage_interface.Vdi.string_of dest_vdi) ;
      finally
        (fun () ->
          debug "activating RW datapath %s on remote" remote_dp ;
          let backend =
            Remote.VDI.attach3 dbg remote_dp dest dest_vdi vm true
          in
          let _, _, _, nbds =
            Storage_interface.implementations_of_backend backend
          in
          let proto =
            match nbds with
            | [] ->
                None
            | uri :: _ ->
                let _socket, export = Storage_interface.parse_nbd_uri uri in
                Some (StreamCommon.Nbd export)
          in
          Remote.VDI.activate3 dbg remote_dp dest dest_vdi vm ;
          with_activated_disk ~dbg ~sr ~vdi:base_vdi ~dp:base_dp ~vm
            (fun base_path ->
              with_activated_disk ~dbg ~sr ~vdi:(Some vdi) ~dp:leaf_dp ~vm
                (fun src ->
                  let verify_cert =
                    if verify_dest then Stunnel_client.pool () else None
                  in
                  let dd =
                    Sparse_dd_wrapper.start
                      ~progress_cb:(progress_callback 0.05 0.9 task)
                      ~verify_cert ~proto ?base:base_path true (Option.get src)
                      dest_vdi_url remote_vdi.virtual_size
                  in
                  Storage_task.with_cancel task
                    (fun () -> Sparse_dd_wrapper.cancel dd)
                    (fun () ->
                      try Sparse_dd_wrapper.wait dd
                      with Sparse_dd_wrapper.Cancelled ->
                        Storage_task.raise_cancelled task
                    )
              )
          )
        )
        (fun () ->
          Remote.DP.destroy dbg remote_dp false ;
          State.remove_copy id
        ) ;
      SXM.info "%s: copy complete for local_vdi:%s dest_vdi:%s" __FUNCTION__
        (Storage_interface.Vdi.string_of vdi)
        (Storage_interface.Vdi.string_of dest_vdi) ;
      debug "setting remote content_id <- %s" local_vdi.content_id ;
      Remote.VDI.set_content_id dbg dest dest_vdi local_vdi.content_id ;
      (* PR-1255: XXX: this is useful because we don't have content_ids by default *)
      debug "setting local content_id <- %s" local_vdi.content_id ;
      Local.VDI.set_content_id dbg sr local_vdi.vdi local_vdi.content_id ;
      Some (Vdi_info remote_vdi)
    with e ->
      error "Caught %s: performing cleanup actions" (Printexc.to_string e) ;
      perform_cleanup_actions !on_fail ;
      raise e

  (** [copy_into_sr] does not requires a dest vdi to be provided, instead, it will 
  find the nearest vdi on the [dest] sr, and if there is no such vdi, it will 
  create one. *)
  let copy_into_sr ~task ~dbg ~sr ~vdi ~vm ~url ~dest ~verify_dest =
    debug "copy sr:%s vdi:%s url:%s dest:%s verify_dest:%B"
      (Storage_interface.Sr.string_of sr)
      (Storage_interface.Vdi.string_of vdi)
      url
      (Storage_interface.Sr.string_of dest)
      verify_dest ;
    let remote_url = Storage_utils.connection_args_of_uri ~verify_dest url in
    let module Remote = StorageAPI (Idl.Exn.GenClient (struct
      let rpc =
        Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2" remote_url
    end)) in
    (* Find the local VDI *)
    try
      let vdis = Local.SR.scan dbg sr in
      let local_vdi =
        try List.find (fun x -> x.vdi = vdi) vdis
        with Not_found -> failwith (Printf.sprintf "Local VDI not found")
      in
      try
        let similar_vdis = Local.VDI.similar_content dbg sr vdi in
        let similars = List.map (fun vdi -> vdi.content_id) similar_vdis in
        debug "Similar VDIs = [ %s ]"
          (String.concat "; "
             (List.map
                (fun x ->
                  Printf.sprintf "(vdi=%s,content_id=%s)"
                    (Storage_interface.Vdi.string_of x.vdi)
                    x.content_id
                )
                similar_vdis
             )
          ) ;
        let remote_vdis = Remote.SR.scan dbg dest in
        (* We drop cbt_metadata VDIs that do not have any actual data *)
        let remote_vdis =
          List.filter (fun vdi -> vdi.ty <> "cbt_metadata") remote_vdis
        in
        let nearest =
          List.fold_left
            (fun acc content_id ->
              match acc with
              | Some _ ->
                  acc
              | None -> (
                try
                  Some
                    (List.find
                       (fun vdi ->
                         vdi.content_id = content_id
                         && vdi.virtual_size <= local_vdi.virtual_size
                       )
                       remote_vdis
                    )
                with Not_found -> None
              )
            )
            None similars
        in
        debug "Nearest VDI: content_id=%s vdi=%s"
          (Option.fold ~none:"None" ~some:(fun x -> x.content_id) nearest)
          (Option.fold ~none:"None"
             ~some:(fun x -> Storage_interface.Vdi.string_of x.vdi)
             nearest
          ) ;
        let remote_base =
          match nearest with
          | Some vdi ->
              debug "Cloning VDI" ;
              let vdi_clone = Remote.VDI.clone dbg dest vdi in
              debug "Clone: %s" (Storage_interface.Vdi.string_of vdi_clone.vdi) ;
              ( if vdi_clone.virtual_size <> local_vdi.virtual_size then
                  let new_size =
                    Remote.VDI.resize dbg dest vdi_clone.vdi
                      local_vdi.virtual_size
                  in
                  debug "Resize remote clone VDI to %Ld: result %Ld"
                    local_vdi.virtual_size new_size
              ) ;
              vdi_clone
          | None ->
              debug "Creating a blank remote VDI <1>" ;
              Remote.VDI.create dbg dest {local_vdi with sm_config= []}
        in
        let remote_copy =
          copy_into_vdi ~task ~dbg ~sr ~vdi ~vm ~url ~dest
            ~dest_vdi:remote_base.vdi ~verify_dest
          |> vdi_info
        in
        let snapshot = Remote.VDI.snapshot dbg dest remote_copy in
        Remote.VDI.destroy dbg dest remote_copy.vdi ;
        Some (Vdi_info snapshot)
      with e ->
        error "Caught %s: copying snapshots vdi" (Printexc.to_string e) ;
        raise (Storage_error (Internal_error (Printexc.to_string e)))
    with
    | Storage_error (Backend_error (code, params))
    | Api_errors.Server_error (code, params) ->
        raise (Storage_error (Backend_error (code, params)))
    | e ->
        raise (Storage_error (Internal_error (Printexc.to_string e)))

  let start ~task ~dbg ~sr ~vdi ~image_format ~dp ~mirror_vm ~copy_vm ~url ~dest
      ~verify_dest =
    SXM.info
      "%s sr:%s vdi:%s dp: %s mirror_vm: %s copy_vm: %s url:%s dest:%s \
       verify_dest:%B"
      __FUNCTION__
      (Storage_interface.Sr.string_of sr)
      (Storage_interface.Vdi.string_of vdi)
      dp
      (Storage_interface.Vm.string_of mirror_vm)
      (Storage_interface.Vm.string_of copy_vm)
      url
      (Storage_interface.Sr.string_of dest)
      verify_dest ;
    let remote_url = Http.Url.of_string url in
    let module Remote = StorageAPI (Idl.Exn.GenClient (struct
      let rpc =
        Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2"
          (Storage_utils.connection_args_of_uri ~verify_dest url)
    end)) in
    (* Find the local VDI *)
    let vdis = Local.SR.scan dbg sr in
    let local_vdi =
      try List.find (fun x -> x.vdi = vdi) vdis
      with Not_found -> failwith "Local VDI not found"
    in
    let mirror_id = State.mirror_id_of (sr, local_vdi.vdi) in
    debug "%s: Adding to active local mirrors before sending: id=%s"
      __FUNCTION__ mirror_id ;
    let alm =
      State.Send_state.
        {
          url
        ; dest_sr= dest
        ; remote_info= None
        ; local_dp= dp
        ; tapdev= None
        ; failed= false
        ; watchdog= None
        }
    in

    State.add mirror_id (State.Send_op alm) ;
    debug "%s Added mirror %s to active local mirrors" __FUNCTION__ mirror_id ;
    (* A list of cleanup actions to perform if the operation should fail. *)
    let on_fail : (unit -> unit) list ref = ref [] in
    try
      let similar_vdis = Local.VDI.similar_content dbg sr vdi in
      let similars =
        List.filter
          (fun x -> x <> "")
          (List.map (fun vdi -> vdi.content_id) similar_vdis)
      in
      debug "Similar VDIs to = [ %s ]"
        (String.concat "; "
           (List.map
              (fun x ->
                Printf.sprintf "(vdi=%s,content_id=%s)"
                  (Storage_interface.Vdi.string_of x.vdi)
                  x.content_id
              )
              similar_vdis
           )
        ) ;
      let (Mirror.Vhd_mirror result) =
        Remote.DATA.MIRROR.receive_start2 dbg dest local_vdi mirror_id
          image_format similars mirror_vm
      in
      (* Enable mirroring on the local machine *)
      let mirror_dp = result.Mirror.mirror_datapath in
      let uri =
        Printf.sprintf "/services/SM/nbd/%s/%s/%s/%s"
          (Storage_interface.Vm.string_of mirror_vm)
          (Storage_interface.Sr.string_of dest)
          (Storage_interface.Vdi.string_of result.Mirror.mirror_vdi.vdi)
          mirror_dp
      in
      debug "%s: uri of http request for mirroring is %s" __FUNCTION__ uri ;
      let dest_url = Http.Url.set_uri remote_url uri in
      let request =
        Http.Request.make
          ~query:(Http.Url.get_query_params dest_url)
          ~version:"1.0" ~user_agent:"smapiv2" Http.Put uri
      in
      let verify_cert = if verify_dest then Stunnel_client.pool () else None in
      let transport = Xmlrpc_client.transport_of_url ~verify_cert dest_url in
      debug "Searching for data path: %s" dp ;
      let attach_info = Local.DP.attach_info dbg sr vdi dp mirror_vm in
      on_fail :=
        (fun () -> Remote.DATA.MIRROR.receive_cancel dbg mirror_id) :: !on_fail ;
      let tapdev =
        match tapdisk_of_attach_info attach_info with
        | Some tapdev ->
            let pid = Tapctl.get_tapdisk_pid tapdev in
            let path =
              Printf.sprintf "/var/run/blktap-control/nbdclient%d" pid
            in
            with_transport ~stunnel_wait_disconnect:false transport
              (with_http request (fun (_response, s) ->
                   let control_fd =
                     Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0
                   in
                   finally
                     (fun () ->
                       Unix.connect control_fd (Unix.ADDR_UNIX path) ;
                       let msg = dp in
                       let len = String.length msg in
                       let written =
                         Unixext.send_fd_substring control_fd msg 0 len [] s
                       in
                       if written <> len then (
                         error "Failed to transfer fd to %s" path ;
                         failwith "Internal error transferring fd to tapdisk"
                       )
                     )
                     (fun () -> Unix.close control_fd)
               )
              ) ;
            tapdev
        | None ->
            failwith "Not attached"
      in
      debug "%s Updating active local mirrors: id=%s" __FUNCTION__ mirror_id ;
      let alm =
        State.Send_state.
          {
            url
          ; dest_sr= dest
          ; remote_info=
              Some
                {
                  dp= mirror_dp
                ; vdi= result.Mirror.mirror_vdi.vdi
                ; url
                ; verify_dest
                }
          ; local_dp= dp
          ; tapdev= Some tapdev
          ; failed= false
          ; watchdog= None
          }
      in

      State.add mirror_id (State.Send_op alm) ;
      debug "%s Updated mirror_id %s in the active local mirror" __FUNCTION__
        mirror_id ;

      SXM.info "%s About to snapshot VDI = %s" __FUNCTION__
        (string_of_vdi_info local_vdi) ;
      let local_vdi = add_to_sm_config local_vdi "mirror" ("nbd:" ^ dp) in
      let local_vdi = add_to_sm_config local_vdi "base_mirror" mirror_id in
      let snapshot =
        try Local.VDI.snapshot dbg sr local_vdi with
        | Storage_interface.Storage_error (Backend_error (code, _))
          when code = "SR_BACKEND_FAILURE_44" ->
            raise
              (Api_errors.Server_error
                 ( Api_errors.sr_source_space_insufficient
                 , [Storage_interface.Sr.string_of sr]
                 )
              )
        | e ->
            raise e
      in
      SXM.info "%s: snapshot created, mirror initiated vdi:%s snapshot_of:%s"
        __FUNCTION__
        (Storage_interface.Vdi.string_of snapshot.vdi)
        (Storage_interface.Vdi.string_of local_vdi.vdi) ;
      on_fail := (fun () -> Local.VDI.destroy dbg sr snapshot.vdi) :: !on_fail ;
      (let rec inner () =
         let alm_opt = State.find_active_local_mirror mirror_id in
         match alm_opt with
         | Some alm ->
             let stats = Tapctl.stats (Tapctl.create ()) tapdev in
             if stats.Tapctl.Stats.nbd_mirror_failed = 1 then (
               error "Tapdisk mirroring has failed" ;
               Updates.add (Dynamic.Mirror mirror_id) updates
             ) ;
             alm.State.Send_state.watchdog <-
               Some
                 (Scheduler.one_shot scheduler (Scheduler.Delta 5)
                    "tapdisk_watchdog" inner
                 )
         | None ->
             ()
       in
       inner ()
      ) ;
      on_fail := (fun () -> Local.DATA.MIRROR.stop dbg mirror_id) :: !on_fail ;
      (* Copy the snapshot to the remote *)
      let new_parent =
        Storage_task.with_subtask task "copy" (fun () ->
            copy_into_vdi ~task ~dbg ~sr ~vdi:snapshot.vdi ~vm:copy_vm ~url
              ~dest ~dest_vdi:result.Mirror.copy_diffs_to ~verify_dest
        )
        |> vdi_info
      in
      debug "Local VDI %s = remote VDI %s"
        (Storage_interface.Vdi.string_of snapshot.vdi)
        (Storage_interface.Vdi.string_of new_parent.vdi) ;
      debug "Local VDI %s now mirrored to remote VDI: %s"
        (Storage_interface.Vdi.string_of local_vdi.vdi)
        (Storage_interface.Vdi.string_of result.Mirror.mirror_vdi.vdi) ;
      debug "Destroying snapshot on src" ;
      Local.VDI.destroy dbg sr snapshot.vdi ;
      Some (Mirror_id mirror_id)
    with
    | Storage_error (Sr_not_attached sr_uuid) ->
        error " Caught exception %s:%s. Performing cleanup."
          Api_errors.sr_not_attached sr_uuid ;
        perform_cleanup_actions !on_fail ;
        raise (Api_errors.Server_error (Api_errors.sr_not_attached, [sr_uuid]))
    | e ->
        error "Caught %s: performing cleanup actions" (Api_errors.to_string e) ;
        perform_cleanup_actions !on_fail ;
        raise e

  let stop ~dbg ~id =
    (* Find the local VDI *)
    let alm = State.find_active_local_mirror id in
    match alm with
    | Some alm ->
        ( match alm.State.Send_state.remote_info with
        | Some remote_info -> (
            let sr, vdi = State.of_mirror_id id in
            let vdis = Local.SR.scan dbg sr in
            let local_vdi =
              try List.find (fun x -> x.vdi = vdi) vdis
              with Not_found ->
                failwith
                  (Printf.sprintf "Local VDI %s not found"
                     (Storage_interface.Vdi.string_of vdi)
                  )
            in
            let local_vdi = add_to_sm_config local_vdi "mirror" "null" in
            let local_vdi = remove_from_sm_config local_vdi "base_mirror" in
            (* Disable mirroring on the local machine *)
            let snapshot = Local.VDI.snapshot dbg sr local_vdi in
            Local.VDI.destroy dbg sr snapshot.vdi ;
            (* Destroy the snapshot, if it still exists *)
            let snap =
              try
                Some
                  (List.find
                     (fun x ->
                       List.mem_assoc "base_mirror" x.sm_config
                       && List.assoc "base_mirror" x.sm_config = id
                     )
                     vdis
                  )
              with _ -> None
            in
            ( match snap with
            | Some s ->
                debug "Found snapshot VDI: %s"
                  (Storage_interface.Vdi.string_of s.vdi) ;
                Local.VDI.destroy dbg sr s.vdi
            | None ->
                debug "Snapshot VDI already cleaned up"
            ) ;
            let remote_url =
              Storage_utils.connection_args_of_uri
                ~verify_dest:remote_info.State.Send_state.verify_dest
                remote_info.State.Send_state.url
            in
            let module Remote = StorageAPI (Idl.Exn.GenClient (struct
              let rpc =
                Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2"
                  remote_url
            end)) in
            try Remote.DATA.MIRROR.receive_cancel dbg id with _ -> ()
          )
        | None ->
            ()
        ) ;
        State.remove_local_mirror id
    | None ->
        raise (Storage_interface.Storage_error (Does_not_exist ("mirror", id)))

  let stat ~dbg:_ ~id =
    let recv_opt = State.find_active_receive_mirror id in
    let send_opt = State.find_active_local_mirror id in
    let copy_opt = State.find_active_copy id in
    let open State in
    let failed =
      match send_opt with
      | Some send_state ->
          let failed =
            match send_state.Send_state.tapdev with
            | Some tapdev -> (
              try
                let stats = Tapctl.stats (Tapctl.create ()) tapdev in
                stats.Tapctl.Stats.nbd_mirror_failed = 1
              with _ ->
                debug "Using cached copy of failure status" ;
                send_state.Send_state.failed
            )
            | None ->
                false
          in
          send_state.Send_state.failed <- failed ;
          failed
      | None ->
          false
    in
    let state =
      (match recv_opt with Some _ -> [Mirror.Receiving] | None -> [])
      @ (match send_opt with Some _ -> [Mirror.Sending] | None -> [])
      @ match copy_opt with Some _ -> [Mirror.Copying] | None -> []
    in
    if state = [] then raise (Storage_error (Does_not_exist ("mirror", id))) ;
    let src, dst =
      match (recv_opt, send_opt, copy_opt) with
      | Some receive_state, _, _ ->
          ( receive_state.Receive_state.remote_vdi
          , receive_state.Receive_state.leaf_vdi
          )
      | _, Some send_state, _ ->
          let dst_vdi =
            match send_state.Send_state.remote_info with
            | Some remote_info ->
                remote_info.Send_state.vdi
            | None ->
                Storage_interface.Vdi.of_string ""
          in
          (snd (of_mirror_id id), dst_vdi)
      | _, _, Some copy_state ->
          (snd (of_copy_id id), copy_state.Copy_state.copy_vdi)
      | _ ->
          failwith "Invalid"
    in
    {Mirror.source_vdi= src; dest_vdi= dst; state; failed}

  let list ~dbg =
    let send_ops, recv_ops, copy_ops = State.map_of () in
    let get_ids map = List.map fst map in
    let ids =
      get_ids send_ops @ get_ids recv_ops @ get_ids copy_ops
      |> Listext.List.setify
    in
    List.map (fun id -> (id, stat ~dbg ~id)) ids

  let killall ~dbg =
    let send_ops, recv_ops, copy_ops = State.map_of () in
    List.iter
      (fun (id, send_state) ->
        debug "Send in progress: %s" id ;
        List.iter log_and_ignore_exn
          [
            (fun () -> stop ~dbg ~id)
          ; (fun () ->
              Local.DP.destroy dbg send_state.State.Send_state.local_dp true
            )
          ]
      )
      send_ops ;
    List.iter
      (fun (id, copy_state) ->
        debug "Copy in progress: %s" id ;
        List.iter log_and_ignore_exn
          [
            (fun () ->
              Local.DP.destroy dbg copy_state.State.Copy_state.leaf_dp true
            )
          ; (fun () ->
              Local.DP.destroy dbg copy_state.State.Copy_state.base_dp true
            )
          ] ;
        let remote_url =
          Storage_utils.connection_args_of_uri
            ~verify_dest:copy_state.State.Copy_state.verify_dest
            copy_state.State.Copy_state.remote_url
        in
        let module Remote = StorageAPI (Idl.Exn.GenClient (struct
          let rpc =
            Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2" remote_url
        end)) in
        List.iter log_and_ignore_exn
          [
            (fun () ->
              Remote.DP.destroy dbg copy_state.State.Copy_state.remote_dp true
            )
          ; (fun () ->
              Remote.VDI.destroy dbg copy_state.State.Copy_state.dest_sr
                copy_state.State.Copy_state.copy_vdi
            )
          ]
      )
      copy_ops ;
    List.iter
      (fun (id, _recv_state) ->
        debug "Receive in progress: %s" id ;
        log_and_ignore_exn (fun () -> Local.DATA.MIRROR.receive_cancel dbg id)
      )
      recv_ops ;
    State.clear ()
end

(** module [MigrateRemote] is similar to [MigrateLocal], but most of these functions
tend to be executed on the receiver side. *)
module MigrateRemote = struct
  let receive_start_common ~dbg ~sr ~vdi_info ~id ~image_format ~similar ~vm =
    let on_fail : (unit -> unit) list ref = ref [] in
    let vdis = Local.SR.scan dbg sr in
    (* We drop cbt_metadata VDIs that do not have any actual data *)
    let vdis = List.filter (fun vdi -> vdi.ty <> "cbt_metadata") vdis in
    let leaf_dp = Local.DP.create dbg Uuidx.(to_string (make ())) in
    try
      let vdi_info = {vdi_info with sm_config= [("base_mirror", id)]} in
      let leaf = Local.VDI.create dbg sr vdi_info in
      info "Created leaf VDI for mirror receive: %s" (string_of_vdi_info leaf) ;
      on_fail := (fun () -> Local.VDI.destroy dbg sr leaf.vdi) :: !on_fail ;
      (* dummy VDI is created so that the leaf VDI becomes a differencing disk,
         useful for calling VDI.compose later on *)
      let dummy = Local.VDI.snapshot dbg sr leaf in
      on_fail := (fun () -> Local.VDI.destroy dbg sr dummy.vdi) :: !on_fail ;
      debug "%s Created dummy snapshot for mirror receive: %s" __FUNCTION__
        (string_of_vdi_info dummy) ;
      let _ : backend = Local.VDI.attach3 dbg leaf_dp sr leaf.vdi vm true in
      Local.VDI.activate3 dbg leaf_dp sr leaf.vdi vm ;
      let nearest =
        List.fold_left
          (fun acc content_id ->
            match acc with
            | Some _ ->
                acc
            | None -> (
              try
                Some
                  (List.find
                     (fun vdi ->
                       vdi.content_id = content_id
                       && vdi.virtual_size <= vdi_info.virtual_size
                     )
                     vdis
                  )
              with Not_found -> None
            )
          )
          None similar
      in
      debug "Nearest VDI: content_id=%s vdi=%s"
        (Option.fold ~none:"None" ~some:(fun x -> x.content_id) nearest)
        (Option.fold ~none:"None"
           ~some:(fun x -> Storage_interface.Vdi.string_of x.vdi)
           nearest
        ) ;
      let parent =
        match nearest with
        | Some vdi ->
            debug "Cloning VDI" ;
            let vdi = add_to_sm_config vdi "base_mirror" id in
            let vdi_clone = Local.VDI.clone dbg sr vdi in
            debug "Clone: %s" (Storage_interface.Vdi.string_of vdi_clone.vdi) ;
            ( if vdi_clone.virtual_size <> vdi_info.virtual_size then
                let new_size =
                  Local.VDI.resize dbg sr vdi_clone.vdi vdi_info.virtual_size
                in
                debug "Resize local clone VDI to %Ld: result %Ld"
                  vdi_info.virtual_size new_size
            ) ;
            vdi_clone
        | None -> (
            debug "Creating a blank remote VDI <2>" ;
            debug "image_format is set to <%s>" image_format ;
            match image_format with
            | "" ->
                Local.VDI.create dbg sr vdi_info
            | _ ->
                Local.VDI.create dbg sr
                  {
                    vdi_info with
                    sm_config= ("type", image_format) :: vdi_info.sm_config
                  }
          )
      in
      debug "Parent disk content_id=%s" parent.content_id ;
      State.add id
        State.(
          Recv_op
            Receive_state.
              {
                sr
              ; dummy_vdi= dummy.vdi
              ; leaf_vdi= leaf.vdi
              ; leaf_dp
              ; parent_vdi= parent.vdi
              ; remote_vdi= vdi_info.vdi
              ; mirror_vm= vm
              }
        ) ;
      let nearest_content_id = Option.map (fun x -> x.content_id) nearest in
      Mirror.Vhd_mirror
        {
          Mirror.mirror_vdi= leaf
        ; mirror_datapath= leaf_dp
        ; copy_diffs_from= nearest_content_id
        ; copy_diffs_to= parent.vdi
        ; dummy_vdi= dummy.vdi
        }
    with e ->
      List.iter
        (fun op ->
          try op ()
          with e ->
            debug "Caught exception in on_fail: %s" (Printexc.to_string e)
        )
        !on_fail ;
      raise e

  let receive_start ~dbg ~sr ~vdi_info ~id ~image_format ~similar =
    receive_start_common ~dbg ~sr ~vdi_info ~id ~image_format ~similar
      ~vm:(Vm.of_string "0")

  let receive_start2 ~dbg ~sr ~vdi_info ~id ~image_format ~similar ~vm =
    receive_start_common ~dbg ~sr ~vdi_info ~image_format ~id ~similar ~vm

  let receive_finalize ~dbg ~id =
    let recv_state = State.find_active_receive_mirror id in
    let open State.Receive_state in
    Option.iter (fun r -> Local.DP.destroy dbg r.leaf_dp false) recv_state ;
    State.remove_receive_mirror id

  let receive_finalize2 ~dbg ~id =
    let recv_state = State.find_active_receive_mirror id in
    let open State.Receive_state in
    Option.iter
      (fun r ->
        SXM.info
          "%s Mirror done. Compose on the dest sr %s parent %s and leaf %s"
          __FUNCTION__ (Sr.string_of r.sr)
          (Vdi.string_of r.parent_vdi)
          (Vdi.string_of r.leaf_vdi) ;
        Local.DP.destroy2 dbg r.leaf_dp r.sr r.leaf_vdi r.mirror_vm false ;
        Local.VDI.compose dbg r.sr r.parent_vdi r.leaf_vdi ;
        (* On SMAPIv3, compose would have removed the now invalid dummy vdi, so
           there is no need to destroy it anymore, while this is necessary on SMAPIv1 SRs. *)
        log_and_ignore_exn (fun () -> Local.VDI.destroy dbg r.sr r.dummy_vdi) ;
        Local.VDI.remove_from_sm_config dbg r.sr r.leaf_vdi "base_mirror"
      )
      recv_state ;
    State.remove_receive_mirror id

  let receive_cancel ~dbg ~id =
    let receive_state = State.find_active_receive_mirror id in
    let open State.Receive_state in
    Option.iter
      (fun r ->
        log_and_ignore_exn (fun () -> Local.DP.destroy dbg r.leaf_dp false) ;
        List.iter
          (fun v -> log_and_ignore_exn (fun () -> Local.VDI.destroy dbg r.sr v))
          [r.dummy_vdi; r.leaf_vdi; r.parent_vdi]
      )
      receive_state ;
    State.remove_receive_mirror id
end

exception Timeout of Mtime.Span.t

let reqs_outstanding_timeout = Mtime.Span.(150 * s)

let pp_time () = Fmt.str "%a" Mtime.Span.pp

(* Tapdisk should time out after 2 mins. We can wait a little longer *)

let pre_deactivate_hook ~dbg:_ ~dp:_ ~sr ~vdi =
  let open State.Send_state in
  let id = State.mirror_id_of (sr, vdi) in
  let start = Mtime_clock.counter () in
  State.find_active_local_mirror id
  |> Option.iter (fun s ->
         (* We used to pause here and then check the nbd_mirror_failed key. Now, we poll
            					   until the number of outstanding requests has gone to zero, then check the
            					   status. This avoids confusing the backend (CA-128460) *)
         try
           match s.tapdev with
           | None ->
               ()
           | Some tapdev ->
               let open Tapctl in
               let ctx = create () in
               let rec wait () =
                 let elapsed = Mtime_clock.count start in
                 if Mtime.Span.compare elapsed reqs_outstanding_timeout > 0 then
                   raise (Timeout elapsed) ;
                 let st = stats ctx tapdev in
                 if st.Stats.reqs_outstanding > 0 then (
                   Thread.delay 1.0 ; wait ()
                 ) else
                   (st, elapsed)
               in
               let st, elapsed = wait () in
               debug "Got final stats after waiting %a" pp_time elapsed ;
               if st.Stats.nbd_mirror_failed = 1 then (
                 error "tapdisk reports mirroring failed" ;
                 s.failed <- true
               )
         with
         | Timeout elapsed ->
             error
               "Timeout out after %a waiting for tapdisk to complete all \
                outstanding requests"
               pp_time elapsed ;
             s.failed <- true
         | e ->
             error "Caught exception while finally checking mirror state: %s"
               (Printexc.to_string e) ;
             s.failed <- true
     )

let post_deactivate_hook ~sr ~vdi ~dp:_ =
  let open State.Send_state in
  let id = State.mirror_id_of (sr, vdi) in
  State.find_active_local_mirror id
  |> Option.iter (fun r ->
         let verify_dest =
           Option.fold ~none:false
             ~some:(fun ri -> ri.verify_dest)
             r.remote_info
         in
         let remote_url =
           Storage_utils.connection_args_of_uri ~verify_dest r.url
         in
         let module Remote = StorageAPI (Idl.Exn.GenClient (struct
           let rpc =
             Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2"
               remote_url
         end)) in
         let t =
           Thread.create
             (fun () ->
               debug "Calling receive_finalize2" ;
               log_and_ignore_exn (fun () ->
                   Remote.DATA.MIRROR.receive_finalize2 "Mirror-cleanup" id
               ) ;
               debug "Finished calling receive_finalize2" ;
               State.remove_local_mirror id ;
               debug "Removed active local mirror: %s" id
             )
             ()
         in
         Option.iter (fun id -> Scheduler.cancel scheduler id) r.watchdog ;
         debug "Created thread %d to call receive finalize and dp destroy"
           (Thread.id t)
     )

let nbd_handler req s ?(vm = "0") sr vdi dp =
  debug "%s: vm=%s sr=%s vdi=%s dp=%s" __FUNCTION__ vm sr vdi dp ;
  let sr, vdi = Storage_interface.(Sr.of_string sr, Vdi.of_string vdi) in
  req.Http.Request.close <- true ;
  let vm = Vm.of_string vm in
  let path =
    Storage_utils.transform_storage_exn (fun () ->
        Local.DATA.MIRROR.import_activate "nbd" dp sr vdi vm
    )
  in
  Http_svr.headers s (Http.http_200_ok () @ ["Transfer-encoding: nbd"]) ;
  let control_fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  finally
    (fun () ->
      Unix.connect control_fd (Unix.ADDR_UNIX path) ;
      let msg = dp in
      let len = String.length msg in
      let written = Unixext.send_fd_substring control_fd msg 0 len [] s in

      if written <> len then (
        error "Failed to transfer fd to %s" path ;
        Http_svr.headers s (Http.http_404_missing ~version:"1.0" ()) ;
        req.Http.Request.close <- true
      )
    )
    (fun () -> Unix.close control_fd)

(** nbd_proxy is a http handler but will turn the http connection into an nbd connection.
It proxies the connection between the sender and the generic nbd server, as returned
by [get_nbd_server dp sr vdi vm]. *)
let nbd_proxy req s vm sr vdi dp =
  debug "%s: vm=%s sr=%s vdi=%s dp=%s" __FUNCTION__ vm sr vdi dp ;
  let sr, vdi = Storage_interface.(Sr.of_string sr, Vdi.of_string vdi) in
  req.Http.Request.close <- true ;
  let vm = Vm.of_string vm in
  let path =
    Storage_utils.transform_storage_exn (fun () ->
        Local.DATA.MIRROR.get_nbd_server "nbd" dp sr vdi vm
    )
  in
  debug "%s got nbd server path %s" __FUNCTION__ path ;
  Http_svr.headers s (Http.http_200_ok () @ ["Transfer-encoding: nbd"]) ;
  let control_fd = Unixext.open_connection_unix_fd path in
  finally
    (fun () ->
      let s' = Unix.dup s in
      let control_fd' = Unix.dup control_fd in
      debug "%s: Connected; running proxy (between fds: %d and %d)" __FUNCTION__
        (Unixext.int_of_file_descr control_fd')
        (Unixext.int_of_file_descr s') ;
      Unixext.proxy s' control_fd' ;
      debug "%s: proxy exited" __FUNCTION__
    )
    (fun () -> Unix.close control_fd)

let with_task_and_thread ~dbg f =
  let task =
    Storage_task.add tasks dbg.Debug_info.log (fun task ->
        Storage_task.set_tracing task dbg.Debug_info.tracing ;
        try f task with
        | Storage_error (Backend_error (code, params))
        | Api_errors.Server_error (code, params) ->
            raise (Storage_error (Backend_error (code, params)))
        | Storage_error (Unimplemented msg) ->
            raise (Storage_error (Unimplemented msg))
        | e ->
            raise (Storage_error (Internal_error (Printexc.to_string e)))
    )
  in
  let _ =
    Thread.create
      (fun () ->
        Storage_task.run task ;
        signal (Storage_task.id_of_handle task)
      )
      ()
  in
  Storage_task.id_of_handle task

(* The following functions acts as wrappers of the migration part of SMAPIv2. Some of
   them are just direct calling of the functions inside the Migrate module. Leave it
   this way so that they all stay in one place rather than being spread around the
   file. *)

let copy ~dbg ~sr ~vdi ~vm ~url ~dest ~verify_dest =
  with_task_and_thread ~dbg (fun task ->
      MigrateLocal.copy_into_sr ~task ~dbg:dbg.Debug_info.log ~sr ~vdi ~vm ~url
        ~dest ~verify_dest
  )

let start ~dbg ~sr ~vdi ~image_format ~dp ~mirror_vm ~copy_vm ~url ~dest
    ~verify_dest =
  with_task_and_thread ~dbg (fun task ->
      MigrateLocal.start ~task ~dbg:dbg.Debug_info.log ~sr ~vdi ~image_format
        ~dp ~mirror_vm ~copy_vm ~url ~dest ~verify_dest
  )

(* XXX: PR-1255: copy the xenopsd 'raise Exception' pattern *)
let stop ~dbg ~id =
  try MigrateLocal.stop ~dbg ~id with
  | Storage_error (Backend_error (code, params))
  | Api_errors.Server_error (code, params) ->
      raise (Storage_error (Backend_error (code, params)))
  | e ->
      raise e

let list = MigrateLocal.list

let killall = MigrateLocal.killall

let stat = MigrateLocal.stat

let receive_start = MigrateRemote.receive_start

let receive_start2 = MigrateRemote.receive_start2

let receive_finalize = MigrateRemote.receive_finalize

let receive_finalize2 = MigrateRemote.receive_finalize2

let receive_cancel = MigrateRemote.receive_cancel

(* The remote end of this call, SR.update_snapshot_info_dest, is implemented in
 * the SMAPIv1 section of storage_migrate.ml. It needs to access the setters
 * for snapshot_of, snapshot_time and is_a_snapshot, which we don't want to add
 * to SMAPI. *)
let update_snapshot_info_src ~dbg ~sr ~vdi ~url ~dest ~dest_vdi ~snapshot_pairs
    ~verify_dest =
  let remote_url = Storage_utils.connection_args_of_uri ~verify_dest url in
  let module Remote = StorageAPI (Idl.Exn.GenClient (struct
    let rpc =
      Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2" remote_url
  end)) in
  let local_vdis = Local.SR.scan dbg sr in
  let find_vdi ~vdi ~vdi_info_list =
    try List.find (fun x -> x.vdi = vdi) vdi_info_list
    with Not_found ->
      raise (Storage_error (Vdi_does_not_exist (Vdi.string_of vdi)))
  in
  let snapshot_pairs_for_remote =
    List.map
      (fun (local_snapshot, remote_snapshot) ->
        (remote_snapshot, find_vdi ~vdi:local_snapshot ~vdi_info_list:local_vdis)
      )
      snapshot_pairs
  in
  Remote.SR.update_snapshot_info_dest dbg dest dest_vdi
    (find_vdi ~vdi ~vdi_info_list:local_vdis)
    snapshot_pairs_for_remote
