---
title: Add new function to notify cluster events in SMAPIv3 API
layout: default
design_doc: true
revision: 1
status: proposed
revision_history:
- revision_number: 1
  description: Initial version
---

# Introduction

Currently events from cluster are either polled by XAPI (`ha_query_liveset`) each 20s by default, or
XAPI uses a dedicated cluster API `UPDATES.get` that blocks until something happens. Right now the
only consumer of a cluster-stack event today (GFS2/DLM via `dlm_controld`) gets events directly from
the daemon bypassing XAPI entirely. There is no way for a SMAPIv3 plugin to get information from
cluster (e.g. "a host is gone"), without depending on corosync.

The goal of this design is to propose a way for XAPI to forward cluster membership events to SMAPIv3 plugins.
Thus, plugins no longer rely on a particular stack. We study two approaches:

- **A**. Extend the existing XAPI hook scripts so they run on every host
- **B**. Add a new SMAPIv3 call, `Plugin.notify_cluster_event`

# Goals & Non Goals

## Goals

- A SMAPIv3 plugin can be notified that a host has left, or rejoined, the cluster.
- The notification is delivered on **every live host** of the pool, not only the coordinator.
- It still needs to work when the host that disappeared is the coordinator.
- The mechanism is independent of the HA stack used.
- A plugin that doesn't care about cluster events see no change.
- XAPI does not wait for the plugin: notification is asynchronous.

## Non goals

- Replacing DLM for GFS2
- Delivery is best effort and plugins must be idempotent.
 
# Background

## Cluster stacks

A pool runs at most one active cluster stack (`pool.ha_cluster_stack`). XAPI drives HA
through a set of scripts in `/usr/libexec/xapi/cluster-stack/<stack>/`. We will find for
example:
- `ha_query_liveset`
- `ha_propose_master`
- `ha_start_daemon, ha_stop_daemon`
- `ha_set_pool_state`
- `ha_disarm_fencing`
- `ha_set_excluded`

Two stacks are available: **xha** and **corosync** and both stacks provide these scripts.

- **xha** is the historical HA daemon.
    - It computes group of hosts alive, using heartbeats over the network and the statefile (shared SR).
    - A host that loses the liveset fences itself.
    - It doesn't provide DLM (distributed lock manager) and that is why **corosync** has been introduced.
- **Corosync**:
    - It was introduced mainly to provide DLM support for GFS2.
    - A plugin requests it through the `required_cluster_stack` field of its `query_result`.
    - It uses a new datamodel: _ocaml/idl/datamodel_cluster.ml_.
        - two objects: **Cluster**, **Cluster_host**.
    - XAPI talks to it through `xapi-clusterd` (`Cluster_client.LocalClient`).

## Where XAPI monitors membership changes today

There are several places where a host can be considered gone.

- **HA liveset** (xhad or corosync used as the HA stack)
    - There is a background thread `Xapi_ha.Monitor.ha_monitor` that monitors the membership.
    - All hosts query the liveset `Xapi_ha.Monitor.query_liveset_on_all_hosts`.
    - Only the master acts on dead host.
    - XAPI gets a snapshot of the liveset at each poll (`ha_query_liveset`).
    - The master keeps the previous list (`last_liveset_uuids`) in memory (not in database) and compares it with
      the new one to detect changes.
    - Slaves only check that master is still alive. They keep no list and must not touch the database.
    - Hooks fired: `Xapi_hooks.host_pre_declare_dead` and `Xapi_hooks.host_post_declare_dead`, with reason **fenced**.

- **Corosync membership** (clustering enabled, HA not necessarily)
    - Watcher is `Xapi_clustering.Watcher.watch_cluster_change` and call `on_corosync_update`.
    - Runs on the master only.
    - It updates `Cluster_host.live`, `Cluster.is_quorate`, ... and raises alerts.
    - No hooks fired.

- **On clean shutdown or reboot**
    - `Xapi_host_helpers.mark_host_as_dead` is called when Host is shutdown or rebooted.
    - It is called from `db_gc.ml`.
    - Hooks fired: `Xapi_hooks.host_pre_declare_dead` and `Xapi_hooks.host_post_declare_dead`, with reason **clean-shutdown**.

- **API call**
    - `Xapi_host.declare_dead`
        - Hooks fired: `Xapi_hooks.host_pre_declare_dead` and `Xapi_hooks.host_post_declare_dead`, with reason **user**.
    - `Xapi_host.destroy`
        - Hooks fired: `Xapi_hooks.host_pre_declare_dead` and `Xapi_hooks.host_post_declare_dead`, with reason **dbdestroy**.

We see that today:
1. Every existing notification happens on the master only.
2. With corosync and HA disabled, a host leaving the cluster fires no hook at all.
3. Left the membership doesn't mean fenced.
    - A host missing from the liveset has fenced itself with HA on.
    - With corosync and HA off, a host missing from the membership may still be running.

## XAPI hooks

- `ocaml/xapi/xapi_hooks.ml` runs the executables found in `/etc/xapi.d/<hook-name>/`.
- Hooks are run in lexical order, one after the other.
- XAPI waits for each script to finish.
- Arguments are `-hostuuid <uuid> -reason <reason>`.
- Exit code is 0 (success) or 1 (log and continue), anything else raises `XAPI_HOOK_FAILED`.

## SMAPIv3 plumbing

Here is the path followed by a storage call:
```
xapi (every host)
  -> Storage_mux (queue org.xen.xapi.storage) [ocaml/xapi/storage_mux.ml]
    -> queue org.xen.xapi.storage.<sr-type>  one queue per plugin, not per SR
      -> xapi-storage-script  (daemon that listens [ocaml/xapi-storage-script/main.ml])
         SMAPIv2 call -> SMAPIv3 call -> fork/exec
         /usr/libexec/xapi-storage-script/volume/<plugin>/<Interface.method> 
```

- XAPI talks SMAPIv2 (`ocaml/xapi-idl/storage/storage_interface.ml`) to `Storage_mux`.
- `Storage_mux_reg` is a table filled when PBD is plugged. So it only contains the SRs plugged on the host.
- `Storage_mux` looks up the SR in `Storage_mux_reg` to find which queue to use.
- `xapi-storage-script` listens on one queue per plugin directory. It translates the SMAPIv2 call into
  a SMAPIv3 call (`ocaml/xapi-storage/generator/lib/*.ml`).
- It then runs the script named after the SMAPIv3 method in the plugin directory, for example `Plugin.query`
  or `Volume.create`. The arguments go as JSON on stdin, and the result comes back as JSON on stdout.

We can notice that:
- SMAPIv2 has a `Query` module that isn't scoped to an SR. `xapi-storage-script` implements it by calling
  the SMAPIv3 `Plugin.query` and `Plugin.diagnostics`. There is also a `Plugin.ls` but it isn't wired in XAPI.
- Every host runs its own `xapi-storage-script`. So a call made by the local xapi reaches the plugin on the
  same host.

# Event model

The event model is what we tell the plugin. Both approaches carry the same information. Here is
pseudo code to describe it:
```
ClusterEvent {
  kind:   HOST_LEFT    // host no longer in membership, may still be running
        | HOST_FENCED  // host left and is known to be fenced
        | HOST_JOINED   // host is back in the membership
  host: host UUID the event is about
}
```
Then, for each approach we can encode it as:
- **A**: `-event <kind> -hostuuid <host>`
- **B**: a `cluster_event` type in `plugin.ml`

# Common part: detecting membership changes on every host

XAPI must first detect the change on every host. Today it only does that on the master. It is the same for both
approaches:

## xhad

- `ha_monitor` already queries the liveset on every host at `ha_monitor_interval`.
- Each host, not only the master, keeps the previous list of live host UUIDs and compares it with the new one.
- This needs no database access, the UUID come from the liveset itself.
- The list is in memory, so after a restart of XAPI the list is empty. And the first comparison reports
  every host as joined. So the first comparison after a restart is skipped.

## corosync

- *TODO*

## A single entry point

All detection points call one function. For example `Xapi_cluster_events.notify ~event`. The caller (for example
the `ha_monitor` loop) must never wait for the delivery, so `notify` delivers the event in the background.
We see two possibilities.

### one thread per event

`notify` creates a new thread that delivers the event:
  - runs the hook for approach A
  - calls the SMAPIv3 plugin for approach B
It logs the result and exits.

Pros:
- Simple, no shared state
Cons:
- No ordering: two events for the same host run in parallel and can be delivered in the wrong order.
- If a plugin hangs, each new event adds one more blocked thread.  

### a queue with one delivery thread

`notify` pushes the event to an in memory queue and returns immediately. A single thread, started with XAPI,
takes events from the queue one by one and delivers them, with a timeout

Pros:
- Events are delivered in order
- A hanging plugin delays later events, but no threads pile up.
Cons:
- Queue is in memory, so events not yet delivered are lost if XAPI restarts.

One thread per event is enough for a prototype. The queue is the target, because event for a host must be
delivered in order.

# Approach A: run hooks on every host

*WIP*

# Approach B: new SMAPIv3 call `Plugin.notify_cluster_event`

*WIP*
