(*
 * Copyright (C) Citrix Systems Inc.
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

module D = Debug.Make (struct let name = "xapi_pci_helpers" end)

open D
module Unixext = Xapi_stdext_unix.Unixext

type pci_property = {id: int; name: string}

type pci = {
    address: string
  ; vendor: pci_property
  ; device: pci_property
  ; pci_class: pci_property
  ; subsystem_vendor: pci_property option
  ; subsystem_device: pci_property option
  ; related: string list
  ; driver_name: string option
}

let get_driver_name address =
  try
    let driver_path =
      Unix.readlink (Printf.sprintf "/sys/bus/pci/devices/%s/driver" address)
    in
    match Astring.String.cut ~sep:"/" ~rev:true driver_path with
    | Some (_, suffix) ->
        Some suffix
    | None ->
        None
  with _ -> None

let address_of_dev x =
  let open Pci.Pci_dev in
  Printf.sprintf "%04x:%02x:%02x.%d" x.domain x.bus x.dev x.func

(* Check for a PCI device whether it is virtual and remember the result
 * such that it can be looked up later *)
module PCIcache : sig
  type t

  type addr = string (* "0000:37:00.4" *)

  val make : unit -> t

  val is_virtual : t -> addr -> bool
end = struct
  type t = (string, bool) Hashtbl.t

  type addr = string

  (** [is_virtual_pci "0000:37:00.4"] is true, if this designates a
   * virtual PCI function (VF), false otherwise. Only a VF has a "physfn"
   * symbolic link.
   *)
  let is_virtual addr =
    let path = Printf.sprintf "/sys/bus/pci/devices/%s/physfn" addr in
    try
      ignore @@ Unix.readlink path ;
      true
    with _ -> false

  let make () = Hashtbl.create 100

  let is_virtual t addr =
    match Hashtbl.find_opt t addr with
    | Some x ->
        x
    | None ->
        let v = is_virtual addr in
        Hashtbl.replace t addr v ; v
end

(** [is_related_to x y] is true, if two non-virtual PCI devices
 *  only differ in their function.
 *)
let is_related_to cache (x : Pci.Pci_dev.t) (y : Pci.Pci_dev.t) =
  let open Pci.Pci_dev in
  x.domain = y.domain
  && x.bus = y.bus
  && x.dev = y.dev
  && x.func <> y.func
  && (not @@ PCIcache.is_virtual cache @@ address_of_dev x)
  && (not @@ PCIcache.is_virtual cache @@ address_of_dev y)

let get_host_pcis () =
  let default ~msg v =
    match v with
    | Some v ->
        v
    | None ->
        debug "get_host_pcis: empty %s" msg ;
        ""
  in
  let open Pci in
  with_access (fun access ->
      let devs = get_devices access in
      let cache = PCIcache.make () in
      List.map
        (fun d ->
          let open Pci_dev in
          debug "get_host_pcis: vendor=%04x device=%04x class=%04x" d.vendor_id
            d.device_id d.device_class ;
          let vendor =
            {
              id= d.vendor_id
            ; name=
                lookup_vendor_name access d.vendor_id
                |> default ~msg:"vendor name"
            }
          in
          let device =
            {
              id= d.device_id
            ; name=
                lookup_device_name access d.vendor_id d.device_id
                |> default ~msg:"device name"
            }
          in
          let address = address_of_dev d in
          let driver_name = get_driver_name address in
          let subsystem_vendor, subsystem_device =
            match d.subsystem_id with
            | None ->
                (None, None)
            | Some (sv_id, sd_id) ->
                let sv_name =
                  lookup_subsystem_vendor_name access sv_id
                  |> default ~msg:"subsystem vendor name"
                in
                let sd_name =
                  lookup_subsystem_device_name access d.vendor_id d.device_id
                    sv_id sd_id
                  |> default ~msg:"susbsytem device name"
                in
                ( Some {id= sv_id; name= sv_name}
                , Some {id= sd_id; name= sd_name}
                )
          in
          let pci_class =
            {
              id= d.device_class
            ; name=
                lookup_class_name access d.device_class
                |> default ~msg:"class name"
            }
          in
          let related_devs = List.filter (is_related_to cache d) devs in
          {
            address
          ; vendor
          ; device
          ; subsystem_vendor
          ; subsystem_device
          ; pci_class
          ; related= List.map address_of_dev related_devs
          ; driver_name
          }
        )
        devs
  )

let igd_is_whitelisted ~__context pci =
  let vendor_id = Db.PCI.get_vendor_id ~__context ~self:pci in
  List.mem vendor_id !Xapi_globs.igd_passthru_vendor_whitelist

let is_pci_hidden_cmdline ~__context ~self =
  let cmdline =
    match Unixext.read_lines ~path:"/proc/cmdline" with
    | [x] ->
        x
    | _ ->
        failwith "Unable to read cmdline"
  in
  let device = Db.PCI.get_pci_id ~__context ~self in
  let elems = String.split_on_char ' ' cmdline in
  let xen_hide_param = "xen-pciback.hide=" in
  let xen_hide_param_length = String.length xen_hide_param in
  let pciback =
    List.find_map
      (fun s ->
        if String.starts_with ~prefix:xen_hide_param s then
          Some
            (String.sub s xen_hide_param_length
               (String.length s - xen_hide_param_length)
            )
        else
          None
      )
      elems
  in
  (* Look for the device id in the list of hidden devices
   * pciback looks like: "xen-pciback.hide=(<id1>)(<id2>)..." *)
  let contains str substr = Astring.String.is_infix ~affix:substr str in
  match pciback with None -> false | Some value -> contains value device

let determine_dom0_access_status ~__context ~self =
  (* Current hidden status *)
  let is_hidden_cmdline = is_pci_hidden_cmdline ~__context ~self in
  (* Hidden status after reboot *)
  let is_hidden = Pciops.is_pci_hidden ~__context self in
  match (is_hidden_cmdline, is_hidden) with
  | true, true ->
      `disabled
  | false, true ->
      `disable_on_reboot
  | false, false ->
      `enabled
  | true, false ->
      `enable_on_reboot

let update_dom0_access ~__context ~self ~action =
  ( match action with
  | `enable ->
      Pciops.unhide_pci ~__context self
  | `disable ->
      Pciops.hide_pci ~__context self
  ) ;

  let new_access = determine_dom0_access_status ~__context ~self in
  (* Keep up to date deprecated PGPU DB field, to be removed eventually. *)
  let expr = Printf.sprintf {|field "PCI"="%s"|} (Ref.string_of self) in
  let pgpus = Db.PGPU.get_all_records_where ~__context ~expr in
  List.iter
    (fun (pgpu_ref, _) ->
      Db.PGPU.set_dom0_access ~__context ~self:pgpu_ref ~value:new_access
    )
    pgpus ;

  new_access
