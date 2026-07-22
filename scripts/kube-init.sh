#!/bin/bash

params=('dbname' 'db_user' 'db_password' 'db_host')
namespace="clixx-prod"
declare -A values=()

for param in "${params[@]}"; do
    value=$(aws ssm get-parameter --name "/stack/clixx/${param}" \
            --with-decryption \
            --query "Parameter.Value" \
            --output text)
    values[$param]="$value"
done

for key in "${!values[@]}"; do
    echo "${values[$key]}"
done

exec_pod=$(kubectl get pods -n=${namespace} | awk 'NR==2 {print $1}')

declare -A wp_map=( ["dbname"]="DB_NAME" ["db_user"]="DB_USER" ["db_password"]="DB_PASSWORD" ["db_host"]="DB_HOST")

for param in "${!values[@]}"; do
    wp_constant="${wp_map[$param]}"
    new_value="${values[$param]}"
    
    echo "Updating ${wp_constant} in pod ${exec_pod}..."

    kubectl exec -i -n="${namespace}" "${exec_pod}" -- /bin/bash <<EOF
sed "s|define( *'${wp_constant}' *,.*);|define( '${wp_constant}', '${new_value}' );|" /var/www/html/wp-config.php > /tmp/wp-config.tmp && cat /tmp/wp-config.tmp > /var/www/html/wp-config.php && rm /tmp/wp-config.tmp
EOF
done