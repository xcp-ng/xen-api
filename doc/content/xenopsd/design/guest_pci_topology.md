+++
title = "Guest PCI topology"
+++

# Guest PCI Topology

- Based on design done previously upstream but never merged: https://github.com/xapi-project/xen-api/commit/e8b06331227c7dab999e9ccc13c0d786e206d038
- BDF notation explanation: https://wiki.xenproject.org/wiki/Bus:Device.Function_(BDF)_Notation
- Xenopsd: https://xapi-project.github.io/new-docs/xenopsd/index.html

---

# Part I, Background

## Current state

When XAPI wants to start a VM, it talks to `xenopsd` that will do the real job
of starting the VM with its VIF and its Disks and all its devices. Xenopsd
computes the full PCI topology to build the `qemu-dm-<domID>` command. In this
process `QEMU` will place the device on the BUS exactly where `xenopsd` tells
it to via options `-device ...,addr=<slot>`.

We currently support two kinds of device models. Three if we count `qemu-none` that is
used mostly for real PV guests. We support the very old `qemu-upstream-compat`
model and the not that young `qemu-upstream-uefi`. Both are based on the `i440FX`
chipset and its `PIIX3` southbridge.

The PCI device models are:

- Fixed devices (set by the QEMU machine model itself)
  - They are instantiated automatically by `QEMU` as part of the machine type
    (**pc-0.10** for compat and **pc-i440fx-2.10** for uefi).
    - `00:00.0` i440FX Host bridge
    - `00:01.0` PIIX3 (ISA/IDE/USB southbridge)
- Devices fixed by `xenopsd` (common to both models):
  - `00:02.0` VGA
  - `00:03.0` Xen Platform Device

- For _qemu-upstream-compat_:
  - `00:03.0` Xen Platform Device (or Xen PV (Windows) that can also be in the passthrough
  area)
  - `00:04.0` - `00:0a.0` Emulated NICs (max\_emulated is 8 but only 7 slots can be used
  without overlapping the vGPU)
  - `00:0b.0`+ NVIDIA vGPU (index + 11) and other pass-through devices (with a 3-devices
  limit when vGPU is present)
    - Pass-through devices (non-vGPU) have no `addr=` passed to QEMU, QEMU picks the slot
    freely, which means it can change across QEMU versions.
  - Disks use IDE via PIIX3 so no extra PCI slots are needed.

- For _qemu-upstream-uefi_:
  - `00:04.0` - `00:05.0` Emulated NICs (max 2)
  - `00:06.0` Xen PV (used by Windows)
  - `00:07.0` NVMe controller (max 1)
  - `00:08.0`+ Other pass-through devices
  - `00:0b.0`+ NVIDIA vGPU

## Problems

**Xen PV instability:** In compat mode it can be in many different slots. It can be on
`00:02.0` if a Nvidia vGPU is present (which replaces the VGA and frees that slot). It can
be on `00:03.0` if Xen platform is not used. Otherwise it will be placed in the first
available gap in the NIC slot range (starting at slot 4). So adding a vGPU can move the
Xen PV device and Windows doesn't like it. There is an improvement in the UEFI model where
it is fixed at `00:06.0`. It can still appear/disappear based on `has-vendor-device` but
when present it is always at the same address.

**NIC limit:** In compat mode we can only have 7 NICs, the 8th lands at slot `00:0b.0`
which conflicts with the first Nvidia vGPU. In UEFI mode the limit is worse: only 2
emulated NICs are supported.

**Pass-through and vGPU conflict:** In compat mode, pass-through devices are placed freely
by QEMU and Nvidia vGPU starts from `00:0b.0`. In UEFI you can have at most 3 pass-through
devices before overlapping with the first Nvidia vGPU slot.

**Bus capacity:** The PCI bus has 32 slots (devices 0-31). Xen only supports 1 PCI bus and
currently we use only one function per slot. With 8 NICs + reserved slots + vGPU +
pass-through devices, the bus fills up fast.

**No persistence:** Slots are computed by `xenopsd` each time to generate the `qemu`
command line. Nothing is saved in the XAPI database. After a reboot the assignment is
recomputed from scratch, relying on the algorithm being identical across software versions
to produce the same result. XAPI has no knowledge of where each device actually ended up.

## How topology is chosen internally

- In `ocaml/xenopsd/xc/device.ml`:
  - `module Qemu_upstream_compat = Make_qemu_upstream (Config_qemu_upstream_compat)`
- `Make_qemu_upstream` is a functor that takes a config implementing the
  `Qemu_upstream_config` signature and produces a full working backend.
  - Currently two backends exist:
    - `Qemu_upstream_compat` ->`Config_qemu_upstream_compat`
    - `Qemu_upstream_uefi` -> `Config_qemu_upstream_uefi`
  - They define: how many NICs, where is Xen PV, where do pass-through devices go.
- The VM has a key-value `platform["device-model"]` string (e.g. `"qemu-upstream-compat"`).
  - XAPI sets the default in `ocaml/xapi/vm_platform.ml` if nothing is already set:
    - BIOS -> `qemu-upstream-compat`
    - UEFI -> `qemu-upstream-uefi`
  - Xenopsd reads `platform["device-model"]` and selects the model via `choose_qemu_dm`
    in `ocaml/xenopsd/xc/xenops_server_xen.ml`.
- The generated backends are declarative data. Despite this, there are hardcoded paths in
  xenopsd that decide the PCI addresses of certain devices (notably Nvidia vGPU via
  `nvidia_vgpu_first_slot_in_guest = 11` in `ocaml/xapi/xapi_globs.ml`).

**VM lifecycle:**
- When a VM is created: the `platform["device-model"]` key-value is stored in the XAPI
database.
- When the VM starts:
  - XAPI reads the info from its database, runs sanity checks, builds a xenopsd record, and
    posts the request to the message switch (using the xenopsd API).
  - Xenopsd receives the API call, stores the profile in its own database, and calls
    `Profile.of_string` to get e.g. `Profile.Qemu_upstream_uefi`.
  - Xenopsd starts the VM via `VM.create_device_model_exn` in
    `ocaml/xenopsd/xc/xenops_server_xen.ml`. The profile variant is passed to
    `Device.Dm.start`, which relies on `/usr/lib64/xen/bin/qemu-wrapper` to start QEMU
    (VGA address and machine type are hardcoded in that script).

---

# Part II, Specification

## Goals

- Introduce a new device model `qemu-upstream-map` that explicitly stores and reuses the
  full PCI topology across reboots and migrations.
- On first boot, `xenopsd` computes and assigns a BDF to each device and writes
  the full topology to XAPI database.
- On subsequent boots, `xenopsd` reads the stored topology and uses it
  directly, without recomputation.
- Ensure virtual PCI addresses are stable: they do not change when unrelated devices are
  added or removed, and do not change across software upgrades.
- Support at least 7 emulated NICs, matching the number of supported VIFs.
- Support at least 64 pass-through devices.
- Give Xen PV and Xen Platform Device stable, dedicated addresses.
- Remove hardcoded PCI slot numbers from both XAPI and xenopsd.

## Non-goals

- Changing existing device models (`qemu-upstream-compat`, `qemu-upstream-uefi`): they are
  retained exactly as-is.
- PCI hotplug on a running VM.
- Q35 machine type (deferred to future work).
- Automatic upgrade of existing VMs to `qemu-upstream-map` (deferred).

## Requirements

### Stability

- A virtual PCI device's BDF shall not change across VM reboots once assigned.
- A virtual PCI device's BDF shall not change when an unrelated virtual PCI device
  is added or removed.
- The assigned topology shall survive live migration and suspend/resume unchanged.

### Persistence

- XAPI shall store the complete assigned PCI topology in its database per VM.
- On subsequent boots, xenopsd shall read the stored topology from XAPI and use it
  as-is, rather than recomputing it.
- The hardcoded Nvidia vGPU first-slot constant (`nvidia_vgpu_first_slot_in_guest`)
  shall be replaced by an allocation driven by the stored topology.

### Capacity

- The device model shall support at least 7 emulated NICs.
- The device model shall support at least 64 pass-through devices.
- Pass-through devices and vGPUs shall not conflict with each other or with
  emulated NICs.

### Layout stability

- Xen Platform Device shall have a fixed, dedicated PCI address.
- Xen PV shall have a fixed, dedicated PCI address that does not change based on
  which other devices are present.

### Multifunction devices

- PCI functions shall be plugged in reverse order, function 0 must be plugged last.
- If any function of a PCI device is in use, function 0 must always be present.

*Note*: It is a QEMU constraint. In QEMU, a PCI device with multiple functions
is only recognized as a multifunction device if function 0 has the
multifunction bit set in its header. By plugging 1, 2, 3... first, you know at the
time you plug function 0 exactly how many other functions exist.

## New device model: `qemu-upstream-map`

A new device model `qemu-upstream-map` shall be introduced with the following topology:

| Slot | Device |
|---|---|
| `00:00.0` | i440FX Host bridge (QEMU) |
| `00:01.0` | PIIX3 (QEMU) |
| `00:02.0` | VGA or empty |
| `00:03.0` | Xen platform |
| `00:03.1` | Xen PV or empty |
| `00:04.0` | NVMe controller or empty |
| `00:05.0` - `00:0b.0` | Emulated NIC, max 7 (slot = devid + 5) |
| `00:0c.0`+ | Nvidia vGPU, SRIOV NIC, or other pass-through devices |

Pass-through devices from `00:0c.0` onwards are assigned on a first-come first-served
basis using multifunction devices. Unplugging a device leaves a gap rather than
renumbering remaining devices, except for function 0. If you remove function 0
while function 1 is still in use, you have a problem. Function 0 must always be
present. One approach it to take one of the existing function 1+ and move it to
function 0.

### Rationale

- `00:00.0` and `00:01.0` are fixed by the QEMU machine model and cannot be moved.
- `00:02.0` is reserved for VGA; left empty when a vGPU provides display output.
- `00:03.0`/`00:03.1`: Xen Platform and Xen PV share a PCI device. Neither can be
  function 0 of a general-purpose multifunction device because both can be disabled
  (via `disable_pf` or `has-vendor-device`), which would cause other functions on that
  device to lose their address.
- Emulated NICs get their own dedicated PCI slots so that removing NIC 0 does not force
  renumbering of remaining NICs. Since Windows identifies network adapters by
  PCI address, that whould break things. That is why each emulated NIC occupies
  a full PCI slot at function 0, with no other functions on that slot.
- Pass-through devices start at `00:0c.0`, well clear of the emulated NIC range.

## Data model

XAPI shall store a `guest_pci_topology` field on the VM object. This field represents the
complete map of which virtual device occupies each BDF. It is:

- Absent when a VM is first created with `qemu-upstream-map`.
- Populated by xenopsd on the first boot and written back to XAPI before the guest starts.
- Read by xenopsd on all subsequent boots and used as-is (no recomputation).

The stored topology maps each occupied `(slot, function)` pair to a device descriptor:
emulated NIC, NVMe, Xen PV, Xen Platform, Nvidia vGPU, or host PCI pass-through address.

## Backwards compatibility

Existing VMs using `qemu-upstream-compat` or `qemu-upstream-uefi` are not affected. Those
device models are retained unchanged and their slot assignment logic is not modified.

## Open questions

- **Q35 machine type:** Would provide better PCIe support and a larger address space.
  Deferred to a future iteration.
- **BIOS VM support:** NVMe at `00:04.0` requires drivers that old BIOS guests may not
  have. An alternative topology for BIOS VMs may be needed.
- **Automatic upgrade path:** Should existing `qemu-upstream-uefi` VMs be transparently
  upgraded to `qemu-upstream-map`? If so, how is the initial topology populated?
- **Function 0 removal:** When function 0 of a pass-through multifunction device is
  unplugged while other functions are still in use, the options are: disallow the unplug,
  move an existing function 1+ to function 0, or insert a dummy device. Each has
  trade-offs.
