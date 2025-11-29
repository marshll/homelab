apiVersion: cert-manager.step.sm/v1beta1
kind: StepClusterIssuer
metadata:
  name: step-ca-issuer
spec:
  url: "${STEP_CA_URL}"
  provisioner:
    name: "${STEP_CA_PROVISIONER}"
    passwordRef:
      name: step-issuer-credentials
      key: PROVISIONER_PASSWORD
  credentialsRef:
    name: step-issuer-credentials