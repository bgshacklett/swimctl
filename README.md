# swimctl

A swimming pool automation controller


## Install

### Create Secrets

```
kubectl create secret generic github-secrets \
  --from-literal=token="${GH_TOKEN}" \
  --from-literal=owner="${GH_REPO_OWNER}" \
  --from-literal=repo_name="${GH_REPO_NAME}"
```

Be sure to replace the placeholder variables with the correct values.


### Helm Install
helm install node-red oci://ghcr.io/schwarzit/charts/node-red --values values.yml


## Update
helm upgrade node-red oci://ghcr.io/schwarzit/charts/node-red --values values.yml
