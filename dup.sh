SOCK=/var/lib/xcp/xapi
rpc() { curl -s --unix-socket "$SOCK" -H 'Content-Type: text/xml' \
        --data-binary "$1" http://localhost/remote_db_access; }

new_uuid=$(cat /proc/sys/kernel/random/uuid)
new_ref="OpaqueRef:$new_uuid"

pair() { printf '<value><array><data><value><string>%s</string></value><value><string>%s</string></value></data></array></value>' "$1" "$2"; }
fields=$(
  pair uuid                "$new_uuid"
  pair name__label         "LINSTOR resources on XCP-ng"
  pair name__description   "SR plugin which uses Linstor to manage VDIs"
  pair type                linstor
  pair vendor              Vates
  pair copyright           "(C) 2020 Vates"
  pair version             1.0
  pair required_api_version 1.0
  pair configuration       "()"
  pair capabilities        "()"
  pair features            "()"
  pair host_pending_features "()"
  pair other_config        "()"
  pair driver_filename     /opt/xensource/sm/LinstorSR
  pair required_cluster_stack "()"
  pair supported_image_formats "()"
)

rpc "<value><array><data>
  <value><string>create_row</string></value>
  <value><string></string></value>
  <value><array><data>
    <value><string>SM</string></value>
    <value><array><data>$fields</data></array></value>
    <value><string>$new_ref</string></value>
  </data></array></value>
</data></array></value>"
