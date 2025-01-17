#!/usr/bin/env bash

# Reloads the systemd daemon, starts the Taildrop service, and checks its status.
reload_systemd_and_start_taildrop_service() {
  systemctl --user daemon-reload
  systemctl --user restart tailreceive
}

# Creates a file if it does not already exist.
create_file_if_not_exists() {
  local file=$1
  if [[ ! -f ${file} ]]; then
    mkdir -p "$(dirname "${file}")"
    touch "${file}"
  fi
}

# Makes a file executable.
make_executable() {
  local file=$1
  chmod +x "${file}"
}

# Downloads the Tailscale icon if it does not already exist in the specified path.
download_icon() {
  local icon_path="${HOME}/.config/dolphin_service_menus_creator/tailscale.png"
  if [[ ! -f ${icon_path}   ]]; then
    echo "Downloading Tailscale icon..."
    mkdir -p "$(dirname "${icon_path}")"
    curl -L "https://raw.githubusercontent.com/error-try-again/KDE-Dolphin-TailDrop-Plugin/main/tailscale.png" -o "${icon_path}"
  fi
}

# Configures Tailscale for receiving files via Taildrop by setting up a systemd service.
generate_taildrop_service() {
  echo "Setting up Tailscale for Taildrop..."

    # Elevate privileges to configure Tailscale with admin rights.
  sudo tailscale up --operator="${USER}"

  # Define directory for systemd unit files and Taildrop download directory
  local systemd_dir="${HOME}/.config/systemd/user"
  local taildrop_dir="${HOME}/Downloads"

    # Ensure the required directories exist.
    mkdir -p "${systemd_dir}" "${taildrop_dir}"

    # Define and create the systemd service file for managing Taildrop file reception.
    generate_tailreceive_service "${systemd_dir}" "${taildrop_dir}"

    # Enable and start the service, then display its status.
    systemctl --user daemon-reload
    systemctl --user enable --now tailreceive
    systemctl --user status tailreceive
}

# Creates a systemd service file for Taildrop in the specified systemd directory, targeting the Taildrop directory.
generate_tailreceive_service() {
    local systemd_dir=$1
    local taildrop_dir=$2
    
  cat << 'EOF' > "${HOME}/.config/dolphin_service_menus_creator/tailreceive.bash"
#!/usr/bin/env bash

tailscale file get --loop --verbose --conflict=rename "${HOME}/Downloads" | while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q "wrote"; then
        python3 ${HOME}/.config/dolphin_service_menus_creator/tailreceive.py "$line"
    fi
done
EOF
  make_executable "${HOME}/.config/dolphin_service_menus_creator/tailreceive.bash"

  cat << 'EOF' > "${HOME}/.config/dolphin_service_menus_creator/tailreceive.py"
import os
import sys
import mimetypes
import subprocess

line = sys.argv[-1]
line = line[line.find(' ') + 1:]
line = line[:-line[::-1].find(' ') - 1]
line = line[:-line[::-1].find(' ') - 1]
name, path = line.split(' as ')

try:
    if not mimetypes.guess_type(path)[0].startswith('image/'):
        path = '${HOME}/.config/dolphin_service_menus_creator/tailscale.png'
except:
    pass

proc = subprocess.Popen(
    ['notify-send', '-a', 'TailDrop', '-i', f'{path}', '-A', 'Show in Dolphin', 'Recieved', f'{name}',],
    stdout=subprocess.PIPE
)
stdout = proc.communicate()[0].strip()
if stdout != b'':
    os.system('kde-open ${HOME}/Downloads &')
EOF

  cat << EOF > "${systemd_dir}/tailreceive.service"
[Unit]
Description=File Receiver Service for Taildrop

[Service]
UMask=0077
ExecStart=${HOME}/.config/dolphin_service_menus_creator/tailreceive.bash

[Install]
WantedBy=default.target
EOF
}

# Generates a script for sending files via Taildrop.
generate_taildrop_script() {
  local taildrop_script=$1
  local taildrop_exclude=$2

  create_file_if_not_exists "${taildrop_script}"

  cat << 'EOF' > "${taildrop_script}"
#!/usr/bin/env bash

# Simple wrapper around the tailscale CLI to send files to a device.
main() {
    local taildrop_exclude="${HOME}/.config/dolphin_service_menus_creator/taildrop_exclude.txt"
    # Get the status of all devices on tailnet
    status_output=$(tailscale status)
    
    # Initialize lists
    name_list=()
    device_list=()
    
    # Record devices
    while IFS= read -r line
    do
        # Extract friendly name
        friendly_name=$(echo "${line}" | awk '{print $2}')
    
        if [[ -n "${friendly_name}" ]]; then
            if ! grep -Fxq "${friendly_name}" ${taildrop_exclude}; then
                name_list+=("${friendly_name}")
            fi
        fi
    done <<< "${status_output}"
    
    # Test to see variable output
    echo "${status_output}"
    echo "${name_list[@]}"
    echo ""
    
    # Only include online external devices in the list
    # Find host name
    host=$(hostname)
    # Convert to lowercase
    host="${host,,}"
    
    for name in "${name_list[@]}"
    do
        if [[ "${name}" != "${host}" ]]; then
            echo "${name}"
            # Add the friendly name to the list with 'on' state
            device_list+=("${name}" "${name}" on)
        fi
    done
    
    # Test to see variable output
    echo "${device_list[@]}"
    echo ""
    
    # Let the user select a device
    # Determine dialog height based upon number of devices
    height=$((16 * ${#device_list[@]}))
    echo "$height"
    chosen_device=$(kdialog --title 'Taildrop' --radiolist "Choose Device" "${device_list[@]}" --geometry 200x"${height}")
    
    # Display popup if no device is selected
    if [[ -z "${chosen_device}" ]]; then
        kdialog --title 'Taildrop' --passivepopup "No device selected" --icon "${HOME}/Themes/Icons/tailscale.png"
        exit 1
    fi
    
    for file in "$@"
    do
        # If sending a folder
        if [[ -d "${file}" ]]; then
    
            # Create a temporary archive
            tmp_archive="$(mktemp -u).zip"
            zip -czf "${tmp_archive}" -C "$(dirname "${file}")" "${file##*/}"
    
            # If directory is sent, add name to list
            if tailscale file cp "${tmp_archive}" "${chosen_device}": &>/dev/null; then
                list_names+="${file##*/} (directory), "
    
                # Remove the temporary archive after sending
                rm -f "${tmp_archive}"
    
                # Check to see if file was delivered
                if ! tailscale ping -c 1 "${chosen_device}" &>/dev/null ; then
                    kdialog --title 'Taildrop' --passivepopup "'${file}' folder not delivered" --icon "${HOME}/Themes/Icons/tailscale.png"
                    exit 1
                fi
            else
                kdialog --title 'Taildrop' --passivepopup "${file} folder not sent" --icon "${HOME}/Themes/Icons/tailscale.png"
            fi
    
        # If sending a file
        elif [[ -f "${file}" ]]; then
            # If file is sent, add name to list
            if tailscale file cp "${file}" "${chosen_device}": &>/dev/null; then
            list_names+="${file##*/}, "
    
                # Check to see if file was delivered
                if ! tailscale ping -c 1 "${chosen_device}" &>/dev/null ; then
                    kdialog --title 'Taildrop' --passivepopup "'${file}' not delivered" --icon "${HOME}/Themes/Icons/tailscale.png"
                    exit 1
                fi
            else
                kdialog --title 'Taildrop' --passivepopup "${file} not sent" --icon "${HOME}/Themes/Icons/tailscale.png"
                exit 1
            fi
        else
            kdialog --title 'Taildrop' --passivepopup "${file} is not a valid file or directory" --icon "${HOME}/Themes/Icons/tailscale.png"
            exit 1
        fi
    done
    
    list_names="${list_names%, }" # Trim the trailing comma and space
    if [[ -n "${list_names}" ]]; then
        kdialog --title 'Taildrop' --passivepopup "${list_names} sent successfully" --icon "${HOME}/Themes/Icons/tailscale.png"
    fi

}

main "$@"

EOF
  make_executable "${taildrop_script}"
}

# Generates or updates a .desktop file for integrating Taildrop with the KDE service menu.
generate_dot_desktop_file() {
  local taildrop_script=$1
  local desktop_file_path=$2

  create_file_if_not_exists "${desktop_file_path}"

  # Create or update the .desktop file
  cat << EOF > "${desktop_file_path}"
# -*- coding: UTF-8 -*-
[Desktop Entry]
Type=Service
ServiceTypes=KonqPopupMenu/Plugin
MimeType=all/all;
Actions=default_action;
X-KDE-StartupNotify=false
X-KDE-Priority=TopLevel
X-KDE-Submenu=
Name=Taildrop
Icon=${HOME}/.config/dolphin_service_menus_creator/tailscale.png
Exec=${taildrop_script} %F

[Desktop Action default_action]
X-KDE-Priority=TopLevel
X-KDE-Submenu=
Name=Send via Taildrop
Icon=${HOME}/.config/dolphin_service_menus_creator/tailscale.png
Exec=${taildrop_script} %F
EOF

  make_executable "${desktop_file_path}"
}

# Main function
main() {
  local taildrop_script="${HOME}/.config/dolphin_service_menus_creator/taildrop_script.sh"
  local taildrop_exclude="${HOME}/.config/dolphin_service_menus_creator/taildrop_exclude.txt"
  local desktop_file_path="${HOME}/.local/share/kio/servicemenus/Taildrop.desktop"

  generate_taildrop_script "${taildrop_script}"
  create_file_if_not_exists "${taildrop_exclude}"
  generate_dot_desktop_file "${taildrop_script}" "${desktop_file_path}"
  download_icon
  generate_taildrop_service
  reload_systemd_and_start_taildrop_service
  kbuildsycoca5
}

main "$@"
