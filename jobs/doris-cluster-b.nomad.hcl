# Doris cluster downstream — 1 FE + 1 BE, scheduled by Nomad onto the client whose
# meta.doris_cluster is "b".
#
# Why it is written this way (docs/decisions.md ADR-005, docs/research.md §4 and §8):
#
#  * **Static ports, host networking.** Doris ports are part of its protocol, not
#    something a scheduler may choose. The BE registers with the FE by address, the
#    other cluster's BEs pull snapshots from this cluster's BEs by address, and the
#    FE's rpc_port must be identical across FEs. network_mode = "host" gives the
#    containers the VM's routable IP, which is what CCR needs across VMs.
#
#  * **Pinned by meta, not by node name.** The job is identical on any VM; the VM
#    declares which cluster it hosts via client meta. Exactly one Nomad client may
#    carry meta.doris_cluster = "b" — the FE and BE groups must land on the same
#    node, because each interpolates its own node's IP as the cluster address.
#
#  * **Host volumes.** Doris is not stateless. The FE persists its identity into
#    doris-meta and the BE into storage; the official entrypoints skip registration
#    entirely when those directories are already populated, which is exactly the
#    behaviour that makes a restart safe and a lost volume corrupting.
#
#  * **Config shim.** The image's fe.conf/be.conf are left intact and appended to at
#    start. The container filesystem is fresh on every start, so this does not
#    accumulate. enable_feature_binlog must be set from first boot on BOTH clusters —
#    turning it on later requires a restart.
#
# Images (measured via the Docker Hub registry API, amd64, 2026-08-28):
#   apache/doris:fe-3.0.7  1.43 GiB compressed
#   apache/doris:be-3.0.7  2.93 GiB compressed

job "doris-b" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "service"

  meta {
    doris_version = "3.0.7"
    ccr_role      = "downstream"
  }

  #############################################################################
  # Frontend
  #############################################################################
  group "fe" {
    count = 1

    constraint {
      attribute = "${meta.doris_cluster}"
      value     = "b"
    }

    restart {
      attempts = 3
      interval = "10m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      port "http" { static = 8030 }
      port "rpc" { static = 9020 }
      port "query" { static = 9030 }
      port "editlog" { static = 9010 }
    }

    volume "meta" {
      type      = "host"
      source    = "doris-fe-meta"
      read_only = false
    }

    volume "log" {
      type      = "host"
      source    = "doris-fe-log"
      read_only = false
    }

    task "fe" {
      driver = "docker"

      # Let Consul deregister before the process goes away, and give the entrypoint's
      # SIGTERM trap room to run stop_fe.sh rather than being killed mid-write.
      shutdown_delay = "10s"
      kill_timeout   = "60s"
      kill_signal    = "SIGTERM"

      volume_mount {
        volume      = "meta"
        destination = "/opt/apache-doris/fe/doris-meta"
      }

      volume_mount {
        volume      = "log"
        destination = "/opt/apache-doris/fe/log"
      }

      config {
        image        = "apache/doris:fe-3.0.7"
        network_mode = "host"

        # Append our settings to the image's fe.conf, then hand over to the
        # official entrypoint unchanged.
        entrypoint = ["/bin/bash", "-c"]
        args = [
          "cat /local/extra-fe.conf >> /opt/apache-doris/fe/conf/fe.conf && exec bash /usr/local/bin/init_fe.sh",
        ]
      }

      # ELECTION mode. The image requires the node name to be literally "fe${FE_ID}"
      # and the address to be a literal IPv4 — its regex rejects hostnames, which is
      # why Doris FQDN mode is not usable through this entrypoint.
      env {
        FE_SERVERS = "fe1:${attr.unique.network.ip-address}:9010"
        FE_ID      = "1"
      }

      template {
        destination = "local/extra-fe.conf"
        change_mode = "noop"

        data = <<-EOH
        # Appended by Nomad. See docs/research.md §8 (CCR requirements and tuning).

        # CCR needs the binlog on BOTH clusters, from first boot.
        enable_feature_binlog = true

        # CCR tuning.
        max_backup_restore_job_num_per_db       = 2
        ignore_backup_tmp_partitions            = true
        enable_restore_snapshot_rpc_compression = true

        # The image's JDK-17 default heap is already -Xmx8192m, which covers the
        # documented ">= 4 GB FE heap per CCR job" for a small number of jobs.
        EOH
      }

      resources {
        cpu    = 4000
        memory = 8192
      }

      service {
        name     = "doris-b-fe"
        port     = "query"
        provider = "consul"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }

      service {
        name     = "doris-b-fe-http"
        port     = "http"
        provider = "consul"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }

  #############################################################################
  # Backend
  #############################################################################
  group "be" {
    count = 1

    constraint {
      attribute = "${meta.doris_cluster}"
      value     = "b"
    }

    restart {
      attempts = 3
      interval = "10m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      port "be" { static = 9060 }
      port "webserver" { static = 8040 }
      port "heartbeat" { static = 9050 }
      port "brpc" { static = 8060 }
    }

    volume "storage" {
      type      = "host"
      source    = "doris-be-storage"
      read_only = false
    }

    volume "log" {
      type      = "host"
      source    = "doris-be-log"
      read_only = false
    }

    task "be" {
      driver = "docker"

      # See the FE task: clean shutdown matters more here, the BE owns tablet data.
      shutdown_delay = "10s"
      kill_timeout   = "60s"
      kill_signal    = "SIGTERM"

      volume_mount {
        volume      = "storage"
        destination = "/opt/apache-doris/be/storage"
      }

      volume_mount {
        volume      = "log"
        destination = "/opt/apache-doris/be/log"
      }

      config {
        image        = "apache/doris:be-3.0.7"
        network_mode = "host"

        entrypoint = ["/bin/bash", "-c"]
        args = [
          "cat /local/extra-be.conf >> /opt/apache-doris/be/conf/be.conf && exec bash /usr/local/bin/entry_point.sh",
        ]
      }

      # The BE derives the master FE address from the first entry of FE_SERVERS and
      # registers itself with ALTER SYSTEM ADD BACKEND '$BE_ADDR'. BE_ADDR carries the
      # heartbeat port (9050), which is the address SHOW BACKENDS reports — and the
      # address the other cluster's BEs must be able to reach for CCR.
      env {
        FE_SERVERS = "fe1:${attr.unique.network.ip-address}:9010"
        BE_ADDR    = "${attr.unique.network.ip-address}:9050"
      }

      template {
        destination = "local/extra-be.conf"
        change_mode = "noop"

        data = <<-EOH
        # Appended by Nomad. See docs/research.md §8.

        # Must match the FE setting, on both clusters, from first boot.
        enable_feature_binlog = true

        # CCR moves large numbers of tablets in one Thrift message.
        thrift_max_message_size = 2000000000
        EOH
      }

      resources {
        cpu    = 4000
        memory = 16384
      }

      service {
        name     = "doris-b-be"
        port     = "heartbeat"
        provider = "consul"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
