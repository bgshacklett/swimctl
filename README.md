# swimctl

A swimming pool automation controller


## Install

### Prepare the Raspberry Pi

* Enable cgroups:

    ```
    if (grep 'cgroup' /boot/firmware/cmdline.txt >/dev/null); then
      echo 'cgroups config found in /boot/firmware/cmdline.txt'
    else
      sudo sed -i 's/$/\ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
    fi
    ```

* Configure i2c

    ```
    sudo raspi-config nonint do_i2c 0
    ```


### Install k3s using k3sup (ketchup)

From a machine with access to the Pi:
```
export hostname=""  # set hostname
k3sup install --host ${hostname} --user pi
```

### Create Secrets

```
kubectl create secret generic swimctl \
  --from-literal=gh_token="${GH_TOKEN}" \
  --from-literal=gh_owner="${GH_REPO_OWNER}" \
  --from-literal=gh_repo_name="${GH_REPO_NAME}" \
  --from-literal=mqtt_password="${MQTT_PASSWORD}"
```

Be sure to replace the placeholder variables with the correct values.


## Apply Static Manifests

k apply -f .


### Helm Install
helm install node-red oci://ghcr.io/schwarzit/charts/node-red --values values.yml


## Update
helm upgrade node-red oci://ghcr.io/schwarzit/charts/node-red --values values.yml
