let prototyped_of_class = function
  | _ ->
      None

let prototyped_of_field = function
  | "Repository", "gpgkey_path" ->
      Some "22.12.0"
  | "host", "last_software_update" ->
      Some "22.19.0-next"
  | _ ->
      None

let prototyped_of_message = function
  | "Repository", "set_gpgkey_path" ->
      Some "22.12.0"
  | "message", "destroy_many" ->
      Some "22.19.0"
  | _ ->
      None