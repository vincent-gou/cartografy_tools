rm -f /tmp/docker_net_mapping.txt
CONF_OUTPUT=/tmp/net_extractor_info.txt
CONFIG_FILE=/tmp/net_extractor_info.ini
rm -f $CONF_OUTPUT
rm -f $CONFIG_FILE

Command_Detection() {
for command in docker nmcli qemu kubectl qemu teamdctl brctl iptables firewall-cmd ss
do
  if [ -x "$(command -v $command)" ]
    then echo detection.command.$command=yes >> $CONFIG_FILE
    else echo detection.command.$command=no >> $CONFIG_FILE
  fi
done
}

Test_detection() {
if [ $(cat $CONFIG_FILE | grep detection.$1.$2 | cut -f 2 -d '=') = "yes" ]
  then return 0
  else return 1
fi
}

Kernel_Module_Detection() {
  for module in veth bridge ip_tables team
  do
    if [ "$(lsmod | grep $module |awk '{print $1}' | grep -v "$module"_ )" ]
      then echo detection.kernel_module.$module=yes >> $CONFIG_FILE
      else echo detection.kernel_module.$module=no >> $CONFIG_FILE
    fi
  done

}

get_network_mode() {
   docker inspect --format='{{.HostConfig.NetworkMode}}' "$1"
}


created_by_kubelet() {
     [[ $(docker inspect --format='{{.Name}}' "$1") =~ ^/k8s_ ]]
}

get_docker_info() {
for container_id in $(docker ps -q); do
  network_mode=$(get_network_mode "${container_id}")
  # skip the containers whose network_mode is 'host' or 'none',
  # but do NOT skip the container created by kubelet.
  if [[ "${network_mode}" == "host" ||  $(! created_by_kubelet "${container_id}") && "${network_mode}" == "none" ]]; then
    echo "${container_id} => ${network_mode}" >> /tmp/docker_net_mapping.txt
    continue
  fi

  # if one container's network_mode is 'other container',
  # then get its root parent container's network_mode.
  while grep container <<< "${network_mode}" -q; do
    network_mode=$(get_network_mode "${network_mode/container:/}")
    # skip the containers whose network_mode is 'host' or 'none',
    # but do NOT skip the container created by kubelet.
    if [[ "${network_mode}" == "host" ||  $(! created_by_kubelet "${container_id}") && "${network_mode}" == "none" ]]
    then
      echo "${container_id} => ${network_mode}" >> /tmp/docker_net_mapping.txt
      continue 2
    fi
done

  # get current container's 'container_id'.
  pid=$(docker inspect --format='{{.State.Pid}}' "${container_id}")
  name=$(docker inspect --format='{{.Name}}' "${container_id}")
  network=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "${container_id}")
  ip_address=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_id}")
  gateway=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "${container_id}")

  # get the 'id' of veth device in the container.
  veth_id=$(nsenter -t "${pid}" -n ip link show eth0 |grep -oP '(?<=eth0@if)\d+(?=:)')

  # get the 'name' of veth device in the 'docker0' bridge (or other name),
  # which is the peer of veth device in the container.
  veth_name=$(ip link show |sed -nr "s/^${veth_id}: *([^ ]*)@if.*/\1/p")

  echo "${container_id} $pid ${veth_name} $name $network $ip_address $gateway" >> /tmp/docker_net_mapping.txt
done

}

virtualization_detection() {

if [ -x "$(command -v docker)" ]
  then echo OK
  else echo KO
fi
}

# Detection functions
Command_Detection
Kernel_Module_Detection


# Run Physical Card detection
PHYSICAL_NET_DEVICE=$(find /sys/class/net/* -not -lname "*virtual*" | sed -e "s/\// /g" | awk '{print $4}' )
VIRTUAL_BRIDGE_NET_DEVICE=$(find /sys/class/net/* -lname "*br-*" | sed -e "s/\// /g" | awk '{print $4}' )
VIRTUAL_ETHERNET_NET_DEVICE=$(find /sys/class/net/* -lname "*veth**" | sed -e "s/\// /g" | awk '{print $4}' )
LOOPBACK_NET_DEVICE=$(find /sys/class/net/* -lname "*lo" | sed -e "s/\// /g" | awk '{print $4}' )
DOCKER_NET_DEVICE=$(find /sys/class/net/* -lname "*docker*" | sed -e "s/\// /g" | awk '{print $4}' )

echo -e "\t\t\t| Dev \t| Link\t| State\t| Speed\t| IP\t\t\t| Mask\t| Team"
echo -e "\t\t\t ------- ------- ------- ------- ----------------------- ------- -------\t"
for DEV in $PHYSICAL_NET_DEVICE
do
PHYSICAL_NET_DEVICE_LINK_STATE=$(cat /sys/class/net/$DEV/carrier 2>/dev/null >/dev/null && printf "ok" || printf "ko")
PHYSICAL_NET_DEVICE_STATE=$(cat /sys/class/net/$DEV/operstate 2>/dev/null  || printf "down")
PHYSICAL_NET_DEVICE_SPEED=$(cat /sys/class/net/$DEV/speed 2>/dev/null  || printf "down")
PHYSICAL_NET_DEVICE_IP=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 1 -d '/' 2>/dev/null || printf "down")
PHYSICAL_NET_DEVICE_NETMASK=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 2 -d '/' 2>/dev/null || print "down")

  printf "Physical_Net_Device:\t" | tee -a $CONF_OUTPUT
  printf "| $DEV \t" | tee -a $CONF_OUTPUT
  printf "| $PHYSICAL_NET_DEVICE_LINK_STATE \t" | tee -a $CONF_OUTPUT
  printf "| $PHYSICAL_NET_DEVICE_STATE \t" | tee -a $CONF_OUTPUT
  printf "| $PHYSICAL_NET_DEVICE_SPEED \t" | tee -a $CONF_OUTPUT
  printf "%-17s\t" "| $PHYSICAL_NET_DEVICE_IP" | tee -a $CONF_OUTPUT
  printf "| $PHYSICAL_NET_DEVICE_NETMASK \t" | tee -a $CONF_OUTPUT
  Test_detection command teamdctl
  if [[ "$?" == "0" ]]
    then
      Test_detection kernel_module team
      if [[ "$?" == "0" ]]
        then
          PHYSICAL_NET_DEVICE_TEAM=$(ip -o -4 link show dev $DEV | cut -d ' ' -f 9  2>/dev/null || printf "down")
          printf "| $PHYSICAL_NET_DEVICE_TEAM \t" | tee -a $CONF_OUTPUT
      fi
  fi
  echo -e "" | tee -a $CONF_OUTPUT
done
echo ""

echo -e "\t\t\t| Dev\t| IP\t\t| Mask\t|"
echo -e "\t\t\t ------- --------------- ------- \t"
for DEV in $LOOPBACK_NET_DEVICE
do
  NET_DEVICE_IP=$(ip -o -4 addr show dev $DEV | head -1 |  cut -d ' ' -f 7  | cut -f 1 -d '/' 2>/dev/null || printf "down")
  NET_DEVICE_NETMASK=$(ip -o -4 addr show dev $DEV | head -1 | cut -d ' ' -f 7  | cut -f 2 -d '/' 2>/dev/null || print "down")
  printf "Loopback_Device:\t" | tee -a $CONF_OUTPUT
  printf "| $DEV \t" | tee -a $CONF_OUTPUT
  printf "| $NET_DEVICE_IP \t" | tee -a $CONF_OUTPUT
  printf "| $NET_DEVICE_NETMASK \t|" | tee -a $CONF_OUTPUT
  echo -e "" | tee -a $CONF_OUTPUT
  echo ""
done

Test_detection command teamdctl
if [[ "$?" == "0" ]]
  then
    Test_detection kernel_module team
    if [[ "$?" == "0" ]]
      then
        TEAM_DEVICE=$(find /sys/class/net/* -lname "*team*" | sed -e "s/\// /g" | awk '{print $4}' )
        echo -e "\t\t\t| Dev\t| Link\t| State\t| Proto\t| IP\t\t\t| Mask\t"
        echo -e "\t\t\t ------- ------- ------- ------- ----------------------- ------- \t"
        for TEAM_DEV in $TEAM_DEVICE
        do
          TEAM_DEVICE_LINK_STATE=$(cat /sys/class/net/$TEAM_DEV/carrier 2>/dev/null >/dev/null && printf "ok" || printf "ko")
          TEAM_DEVICE_STATE=$(cat /sys/class/net/$TEAM_DEV/operstate 2>/dev/null  || printf "down")
          #TEAM_DEVICE_SPEED=$(cat /sys/class/net/$DEV/speed 2>/dev/null  || printf "down")
          TEAM_DEVICE_IP=$(ip -o -4 addr show dev $TEAM_DEV | cut -d ' ' -f 7  | cut -f 1 -d '/' 2>/dev/null || printf "down")
          TEAM_DEVICE_NETMASK=$(ip -o -4 addr show dev $TEAM_DEV | cut -d ' ' -f 7  | cut -f 2 -d '/' 2>/dev/null || printf "down")
          TEAM_DEVICE_PROTO=$(ip -o -4 addr show dev $TEAM_DEV | grep dynamic &>/dev/null && printf "dhcp" || printf "fixed")
          printf "Teaming_Net_Device:\t" | tee -a $CONF_OUTPUT
          printf "| $TEAM_DEV\t" | tee -a $CONF_OUTPUT
          printf "| $TEAM_DEVICE_LINK_STATE \t" | tee -a $CONF_OUTPUT
          printf "| $TEAM_DEVICE_STATE \t" | tee -a $CONF_OUTPUT
          printf "| $TEAM_DEVICE_PROTO\t" | tee -a $CONF_OUTPUT
          #printf "$TEAM_DEVICE_SPEED \t" | tee -a $CONF_OUTPUT
          printf "%-17s\t" "| $TEAM_DEVICE_IP" | tee -a $CONF_OUTPUT
          printf "| $TEAM_DEVICE_NETMASK \t" | tee -a $CONF_OUTPUT
          echo -e "" | tee -a $CONF_OUTPUT
        done
      echo ""
    fi
  else
      echo "NO TEAM"
fi

Test_detection command docker
if [[ "$?" == "0" ]]
  then
      get_docker_info
      echo -e "\t\t\t| Dev\t\t| State\t| IP\t\t| Mask\t"
      echo -e "\t\t\t --------------- ------- -------------- ------- \t"
      for DEV in $DOCKER_NET_DEVICE
      do
      NET_DEVICE_STATE=$(ip -o -4 link show dev $DEV | cut -d ' ' -f 9 2>/dev/null || printf "down")
      NET_DEVICE_IP=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 1 -d '/' 2>/dev/null || printf "down")
      NET_DEVICE_NETMASK=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 2 -d '/' 2>/dev/null || print "down")
      printf "Docker_Virtual_Device:\t" | tee -a $CONF_OUTPUT
      printf "| $DEV\t" | tee -a $CONF_OUTPUT
      printf "| $NET_DEVICE_STATE\t" | tee -a $CONF_OUTPUT
      printf "| $NET_DEVICE_IP \t" | tee -a $CONF_OUTPUT
      printf "| $NET_DEVICE_NETMASK \t" | tee -a $CONF_OUTPUT
      echo -e "" | tee -a $CONF_OUTPUT
      done
  echo ""
fi

Test_detection command brctl
if [[ "$?" == "0" ]]
  then
    Test_detection kernel_module bridge
    if [[ "$?" == "0" ]]
      then
        echo -e "\t\t\t| Dev\t\t\t| State\t| IP\t\t| Mask\t"
        echo -e "\t\t\t ----------------------- ------- --------------- -------\t"
        for DEV in $VIRTUAL_BRIDGE_NET_DEVICE
        do
          NET_DEVICE_STATE=$(ip -o -4 link show dev $DEV | cut -d ' ' -f 9 2>/dev/null || printf "down")
          NET_DEVICE_IP=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 1 -d '/' 2>/dev/null || printf "down")
          NET_DEVICE_NETMASK=$(ip -o -4 addr show dev $DEV | cut -d ' ' -f 7  | cut -f 2 -d '/' 2>/dev/null || print "down")
          printf "Virtual_Bridge_Device:\t" | tee -a $CONF_OUTPUT
          printf "| $DEV\t" | tee -a $CONF_OUTPUT
          printf "| $NET_DEVICE_STATE\t" | tee -a $CONF_OUTPUT
          printf "| $NET_DEVICE_IP \t" | tee -a $CONF_OUTPUT
          printf "| $NET_DEVICE_NETMASK \t" | tee -a $CONF_OUTPUT
          echo -e "" | tee -a $CONF_OUTPUT
          echo ""
        done
    fi
  fi

Test_detection command docker
if [[ "$?" == "0" ]]
  then
    echo -e "\t\t\t| Dev\t\t| State\t| Container\t| IP\t\t| Docker_network\t| Gateway\t| Bridge"
    echo -e "\t\t\t --------------- ------- --------------- --------------- ----------------------- --------------- ----------\t"
    for DEV in $VIRTUAL_ETHERNET_NET_DEVICE
      do
      NET_DEVICE_STATE=$(ip -o -4 link show dev $DEV | cut -d ' ' -f 11 2>/dev/null || printf "down")
      NET_DEVICE_BRIDGE=$(ip -o -4 link show dev $DEV | cut -d ' ' -f 9  2>/dev/null || printf "down")
      DOCKER_CONTAINER_NAME=$(cat /tmp/docker_net_mapping.txt | grep $DEV | cut -d ' ' -f 4  2>/dev/null || printf "down")
      DOCKER_NETWORK_NAME=$(cat /tmp/docker_net_mapping.txt | grep $DEV | cut -d ' ' -f 5  2>/dev/null || printf "down")
      DOCKER_CONTAINER_IP=$(cat /tmp/docker_net_mapping.txt | grep $DEV | cut -d ' ' -f 6  2>/dev/null || printf "down")
      DOCKER_CONTAINER_GATEWAY=$(cat /tmp/docker_net_mapping.txt | grep $DEV | cut -d ' ' -f 7  2>/dev/null || printf "down")
      printf "Virtual_Ethernet:\t" | tee -a $CONF_OUTPUT
      printf "| $DEV\t" | tee -a $CONF_OUTPUT
      printf "| $NET_DEVICE_STATE\t" | tee -a $CONF_OUTPUT
      printf "%-10s\t" "| $DOCKER_CONTAINER_NAME" | tee -a $CONF_OUTPUT
      printf "%-10s\t" "| $DOCKER_CONTAINER_IP" | tee -a $CONF_OUTPUT
      printf "%-20s\t" "| $DOCKER_NETWORK_NAME" | tee -a $CONF_OUTPUT
      printf "%-10s\t" "| $DOCKER_CONTAINER_GATEWAY" | tee -a $CONF_OUTPUT
      printf "| $NET_DEVICE_BRIDGE\t" | tee -a $CONF_OUTPUT
      echo -e | tee -a $CONF_OUTPUT
      done
    echo ""
fi

Test_detection command iptables
if [[ "$?" == "0" ]]
  then
    Test_detection command firewall-cmd
fi

Test_detection command ss
if [[ "$?" == "0" ]]
  then
    echo -e "\t\t\t| Dev\t\t| State\t| Container\t| IP\t\t| Docker_network\t| Gateway\t| Bridge"
    echo -e "\t\t\t --------------- ------- --------------- --------------- ----------------------- --------------- ----------\t"
fi


Diagram() {
COL=$(tput cols)
echo $COL
echo -e ""
PHYSICAL_CARD=$(cat $CONF_OUTPUT | grep Physical_Net_Device | awk '{print $2}' )
LOOPBACK_CARD=$(cat $CONF_OUTPUT | grep Loopback_Device | awk '{print $2}' )
DOCKER_CARD=$(cat $CONF_OUTPUT | grep Docker_Virtual_Device | awk '{print $2}' )
#NB_PHYSICAL_CARD=$((${#PHYSICAL_CARD[@]} + 1))
NB_PHYSICAL_CARD=${#PHYSICAL_CARD[@]}
NB_LOOPBACK_CARD=${#PHYSICAL_CARD[@]}
NB_DOCKER_CARD=${#DOCKER_CARD[@]}


#INIT=$(($COL / $(($NB_PHYSICAL_CARD + $NB_LOOPBACK_CARD + $NB_DOCKER_CARD))  ))
INIT=$(($COL / $(($NB_PHYSICAL_CARD + $NB_PHYSICAL_CARD ))  ))
#tput cuf $INIT
for DEV in $PHYSICAL_CARD $LOOPBACK_CARD $DOCKER_CARD
do
echo -ne "$DEV"
tput cuf $INIT
INIT=$(($INIT + $INIT))
done


echo -e ""
}

#Diagram
