$PSDefaultParameterValues['Out-File:Encoding'] = 'ascii'

$PropertyFilePath=".\input.properties"
$RawProperties=Get-Content $PropertyFilePath;
$PropertiesToConvert=($RawProperties -replace '\\','\\') -join [Environment]::NewLine;
$Properties=ConvertFrom-StringData $PropertiesToConvert;

Set-Variable -Name "RESOURCE_GROUP" -Value  $Properties["RESOURCE_GROUP"]
Set-Variable -Name "AWS_REGION" -Value      $Properties["AWS_REGION"]
Set-Variable -Name "CLUSTER_NAME" -Value    $Properties["CLUSTER_NAME"]
Set-Variable -Name "DNS_ZONE" -Value        $Properties["DNS_ZONE"]
Set-Variable -Name "ACME_EMAIL" -Value      $Properties["ACME_EMAIL"]

Set-Variable -Name "CALLER_REF" -Value      $(date)

Set-Variable -Name "KUBE_USER" -Value       "terraform@$CLUSTER_NAME.$AWS_REGION.eksctl.io"

Get-Content cluster-issuer.yaml | sed "s/ACME_EMAIL/$ACME_EMAIL/g" > cluster-issuer-$RESOURCE_GROUP.yaml
Get-Content kubernetes-dashboard-ingress.yaml| sed "s/DNS_ZONE/$DNS_ZONE/g" >  kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
Get-Content kiali-ingress.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  kiali-ingress-$RESOURCE_GROUP.yaml
Get-Content api-gateway-deployment-external-elasticsearch.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
Get-Content nodetours.yaml | sed "s/DNS_ZONE/$DNS_ZONE/g" >  nodetours-$RESOURCE_GROUP.yaml

Function pause ($message)
{
    # Check if running Powershell ISE
    if ($psISE)
    {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    }
    else
    {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

if ((Get-Command "eksctl" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  Write-Output "****************************************************"
  Write-Output "Please download and install the AWS CLI and eksctl from: "
  Write-Output "https://docs.aws.amazon.com/eks/latest/userguide/getting-started-eksctl.html"
  Write-Output ""
  Write-Output "Rerun this command when done."
  Write-Output "****************************************************"
  exit
}
if ((Get-Command "istioctl" -ErrorAction SilentlyContinue) -eq $null) 
{ 
  Write-Output "****************************************************"
  Write-Output "Please download the latest Istio Archive from: "
  Write-Output "https://github.com/istio/istio/releases/download/1.5.2/istio-1.5.2-win.zip"
  Write-Output "unzip it somewhere and add the bin folder to your path"
  Write-Output ""
  Write-Output "Rerun this command when done."
  Write-Output "****************************************************"
  exit
}
  
Write-Output "Configuring AWS Connection properties"
aws configure

Write-Output "Checking that the API Gateway and Microgateway images are present"
if (($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/microgateway-trial/ { print $2 }') -ne "10.5.0.2") -or
    ($(docker images | awk '/daerepository03.eur.ad.sag:4443\/softwareag\/apigateway-trial/ { print $2 }') -ne "10.5.0.2"))
{
  if ($(ping -n 1 daerepository03.eur.ad.sag | awk '/Reply from/ { print $1 }') -ne "Reply")
  {
    Write-Output "******************************************************************************"
    Write-Output "Please connect to the VPN to pull the API Gateway & Microgateway docker images"
    Write-Output "******************************************************************************"
    exit
  }
  Write-Output "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2
  Write-Output "Pulling API Microgateway image from internal registry. Ensure you are on the VPN"
  docker pull daerep//ository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2
}

Write-Output "Creating DNS Zone: $DNS_ZONE in AWS with caller-referece [$CALLER_REF]"
aws route53 create-hosted-zone --name $DNS_ZONE --caller-reference=$CALLER_REF > dns-response-$RESOURCE_GROUP.json
cat dns-response-$RESOURCE_GROUP.json
Set-Variable -Name "HOSTED_ZONE_ID" -Value $(cat dns-response-$RESOURCE_GROUP.json | awk '/"""\/hostedzone\// {split($2, a, """/"""); print substr(a[3], 1, length(a[3])-2) }')
echo "HOSTED_ZONE_ID = $HOSTED_ZONE_ID"
Write-Output "****************************************************"
Write-Output "Please ensure your DNS registrar now points $DNS_ZONE to the Azure NameServers above"
Write-Output "****************************************************"
pause "Press any key to continue, when this is done"
Write-Output "Creating EKS Cluster: $CLUSTER_NAME"
eksctl create cluster --name $CLUSTER_NAME --region $AWS_REGION

Write-Output "Listing EKS Cluster nodes"
kubectl get nodes

Write-Output "Creating nginx-ingress namespace"
kubectl create namespace nginx-ingress
kubectl config set-context --current --namespace=nginx-ingress
Write-Output "Adding nginx-ingress repoo to helm"
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
Write-Output "Refreshing helm repoos"
helm repo update
Write-Output "Installing nginx-ingress using helm"
helm install nginx-ingress stable/nginx-ingress  -n nginx-ingress --wait
Write-Output "Getting nginx-ingress IP Address"
Set-Variable -Name "NGINX_INGRESS" -Value $(kubectl get service -l app=nginx-ingress -n nginx-ingress | grep nginx-ingress-controller | awk '{print $4}')
do
{
  Set-Variable -Name "NGINX_INGRESS_IP" -Value $(ping -n 1 $NGINX_INGRESS | grep $NGINX_INGRESS | sed 's/^[^[]*\\[\\([^\\]\*\\)\\].*$/\\1/')
  Start-Sleep 30
  Write-Output "Waiting for DNS names to progagate... ($NGINX_INGRESS_IP)"  
} While ($NGINX_INGRESS_IP -like 'Ping request could not find host*')
Write-Output "Pointing *.$DNS_ZONE to nginx-ingress: $NGINX_INGRESS, NGINX_INGRESS_IP: $NGINX_INGRESS_IP"
Get-Content aws_dns_record.json | sed "s/DNS_ZONE/$DNS_ZONE/g" | sed "s/NGINX_INGRESS/$NGINX_INGRESS/g" > aws_dns_record-$RESOURCE_GROUP.json
aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID  --change-batch file://aws_dns_record-$RESOURCE_GROUP.json
do
{
  Set-Variable -Name "IP_CURRENT" -Value $(ping -n 1 harbor.$DNS_ZONE | grep $NGINX_INGRESS | sed 's/^[^[]*\\[\\([^\\]\*\\)\\].*$/\\1/')
  Start-Sleep 30
  Write-Output "Waiting for DNS names to progagate... ($NGINX_INGRESS_IP - $IP_CURRENT)"  
} While ($NGINX_INGRESS_IP -ne $IP_CURRENT)
Write-Output "DNS names progagated..."
kubectl label namespace nginx-ingress cert-manager.io/disable-validation=true
Write-Output "Adding cert-manager repoo to helm"
helm repo add jetstack https://charts.jetstack.io
Write-Output "Refreshing helm repoos"
helm repo update
Write-Output "Installing cert-manager using helm"
helm install cert-manager --version v0.13.0  jetstack/cert-manager --wait
Write-Output "Wait for cert-manager to be ready..."
Start-Sleep 60
Write-Output "Creating letsencrypt ClusterIssuer"
kubectl apply -f cluster-issuer-$RESOURCE_GROUP.yaml
Write-Output "Install kubernetes-dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
kubectl config set-context --current --namespace=kubernetes-dashboard
Write-Output "Create admin-sa service account"
kubectl create serviceaccount dashboard-admin-sa
Write-Output "Bind admin-sa service account to cluster-admin ClusterRole"
kubectl create clusterrolebinding dashboard-admin-sa --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:dashboard-admin-sa
Write-Output "Get login token secret for admin-sa"
Set-Variable -Name "TOKEN_SECRET" -Value $(kubectl get secret -n kubernetes-dashboard | awk '/dashboard-admin-sa-token-/ { print $1 }')
Set-Variable -Name "TOKEN" -Value $(kubectl describe secret $TOKEN_SECRET -n kubernetes-dashboard | awk '/token:/ { print $2 }')
kubectl config set-credentials $KUBE_USER --token=$TOKEN
Write-Output "Kubernetes-dashboard login token: TOKEN: $TOKEN"
kubectl describe secret $TOKEN_SECRET
Write-Output "Create kubernetes-dashboard ingress on address: kubernetes-dashboard.$DNS_ZONE"
kubectl apply -f kubernetes-dashboard-ingress-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/kubernetes-dashboard-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Kubernetes-Dashboard certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output "Create registries namespace..."
kubectl create namespace registries
kubectl config set-context --current --namespace=registries
Write-Output "Install harbor using helm"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install harbor bitnami/harbor --set service.type=Ingress --set service.ingress.hosts.core=harbor.$DNS_ZONE --set service.ingress.annotations.'cert-manager\.io/cluster-issuer'=letsencrypt --set service.ingress.annotations.'kubernetes\.io/ingress\.class'=nginx --set externalURL=https://harbor.$DNS_ZONE --set service.tls.secretName=bitnami-harbor-ingress-cert --set notary.enabled=false --wait
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/bitnami-harbor-ingress-cert/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Harbor certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output Password: $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d)

Write-Output "Push API Gateway and API Microgateway to harbor"
Write-Output $(kubectl get secret --namespace registries harbor-core-envvars -o jsonpath="{.data.HARBOR_ADMIN_PASSWORD}" | base64 -i -d) | docker login -u admin --password-stdin harbor.$DNS_ZONE/library
docker tag daerepository03.eur.ad.sag:4443/softwareag/apigateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/apigateway-trial:10.5.0.2
docker tag daerepository03.eur.ad.sag:4443/softwareag/microgateway-trial:10.5.0.2  harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2
docker push harbor.$DNS_ZONE/library/softwareag/microgateway-trial:10.5.0.2

Write-Output "Install istio"
istioctl manifest apply --set profile=demo
Write-Output "Create Kiali ingress"
kubectl apply -f .\kiali-ingress-$RESOURCE_GROUP.yaml -n istio-system
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate -n istio-system | awk '/kiali-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for Kiali certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

Write-Output "Create registries namespace..."
kubectl create namespace monitoring
kubectl config set-context --current --namespace=monitoring
Write-Output "Installing Elastic DaemonSet to ensure ulimits increased"
kubectl apply -f .\es-sysctl-ds.yaml
Write-Output "Installing Elastic Search"
kubectl apply -f .\elasticsearch.yaml
do
{
  Set-Variable -Name "PODS_READY" -Value $(kubectl get pods | awk '/elasticsearch-deployment-/ { print $2 }')
  Start-Sleep 10
  Write-Output "Waiting for pods to be ready... ($PODS_READY)"  
} While ($PODS_READY -ne "1/1")
Write-Output "Pods ready..."

Write-Output "Create nodetours namespace..."
kubectl create namespace nodetours
kubectl config set-context --current --namespace=nodetours
Write-Output "Disabling istio injection on the nodetours namespace before installing API Gateway installation"
kubectl label namespace nodetours istio-injection=disabled --overwrite=true
Write-Output "Installing API Gateway"
kubectl apply -f .\api-gateway-deployment-external-elasticsearch-$RESOURCE_GROUP.yaml
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/api-gateway-tls-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."
Write-Output "Checking status of API Gateway pods"
do
{
  Set-Variable -Name "PODS_READY" -Value $(kubectl get pods | awk '/api-gateway-deployment-/ { print $2 }')
  Start-Sleep 10
  Write-Output "Waiting for pods to be ready... ($PODS_READY)"  
} While ($PODS_READY -ne "1/1")
Write-Output "Pods ready..."

Write-Output "Enabling istio injection on nodetours namespace"
kubectl label namespace nodetours istio-injection=enabled --overwrite=true
Write-Output "Installing nodetours demo"
kubectl apply -f .\nodetours-$RESOURCE_GROUP.yaml
Write-Output "Checking status of Nodetours demo pods"
do
{
  Set-Variable -Name "PODS_READY" -Value $(kubectl get pods | awk '/nodetours-/ { print $2 }')
  Start-Sleep 10
  Write-Output "Waiting for pods to be ready... ($PODS_READY)"  
} While ($PODS_READY -ne "3/3")
Write-Output "Pods ready..."
do
{
  Set-Variable -Name "CERT_READY" -Value $(kubectl get certificate | awk '/nodetours-tls-secret/ { print $2 }')
  Start-Sleep 30
  Write-Output "Waiting for nodetours certificate to be generated... ($CERT_READY)"  
} While ($CERT_READY -ne "True")
Write-Output "Certificate ready..."

kubectl get pods