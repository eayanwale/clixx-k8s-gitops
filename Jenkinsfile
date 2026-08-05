def runner = "ENOCH"

pipeline {
    agent any

    options {
        ansiColor('xterm')
    }

    triggers {
        githubPush()
    }

    parameters {
        booleanParam(name: 'RECREATE_GIT_CREDS', defaultValue: true, description: 'Recreate the git-creds secret (argocd ns) from the Jenkins-stored GitHub PAT')
    }

    environment {
        AWS_REGION       = 'us-east-1'
        AWS_PROFILE      = 'stackprog-dev'   // assumes role/Engineer in the dev account via EC2 instance metadata, see ~/.aws/config 
        ECR_REGISTRY     = '111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository'
        EC2_INSTANCE_IDS = 'i-0aaaaaaaaaaaaaaa3 i-0aaaaaaaaaaaaaaa6 i-0aaaaaaaaaaaaaaa4'
        RDS_INSTANCE_ID  = 'k8s-clixx-db'
        CP_USER          = 'ubuntu'
        CP_TAG_NAME      = 'k8control'   
        ARGOCD_MANIFEST  = 'https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml'
        IMAGE_UPDATER_MANIFEST = 'https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml'
        SSH_OPTS         = '-o StrictHostKeyChecking=accept-new'
        RECREATE_GIT_CREDS = "${params.RECREATE_GIT_CREDS}"
        MCP_NAME         = 'clixx-k8s'
        MCP_VENV_PYTHON  = '/home/ubuntu/mcp-venv/bin/python'
        MCP_SERVER_PATH  = '/home/ubuntu/server.py'
    }

    stages {

        stage('Check infra state & start if needed') {
            steps {
                script {
                    def ec2States = sh(
                        script: 'aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --instance-ids $EC2_INSTANCE_IDS --query "Reservations[].Instances[].State.Name" --output text',
                        returnStdout: true
                    ).trim()
                    def rdsState = sh(
                        script: 'aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID" --query "DBInstances[0].DBInstanceStatus" --output text',
                        returnStdout: true
                    ).trim()

                    def ec2AllRunning = ec2States.split(/\s+/).every { it == 'running' }
                    env.INFRA_WAS_STOPPED = (!ec2AllRunning || rdsState != 'available') ? 'true' : 'false'

                    echo "EC2 states: ${ec2States} | RDS state: ${rdsState}"

                    if (ec2AllRunning) {
                        echo 'All EC2 instances already running - skipping start-instances.'
                    } else {
                        sh 'aws ec2 start-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --instance-ids $EC2_INSTANCE_IDS'
                    }

                    if (rdsState == 'available') {
                        echo 'RDS already available - skipping start-db-instance.'
                    } else if (rdsState == 'stopped') {
                        sh 'aws rds start-db-instance --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID"'
                    } else {
                        echo "RDS in transient state '${rdsState}' (not stopped, not available) - leaving it alone rather than risk an invalid-state API error."
                    }
                }
            }
        }

        stage('Notify start') {
            steps {
                script {
                    def action = (env.INFRA_WAS_STOPPED == 'true') ? 'WAKING INFRA + SYNCING' : 'SYNCING'
                    slackSend (
                        color: '#FFFF00',
                        message: """
                    --${action}--
Runner: ${runner}
Job: ${env.JOB_BASE_NAME} [${env.BUILD_NUMBER}]
Build: (${env.BUILD_URL})
"""
                    )
                }
            }
        }

        stage('Wait for infra readiness') {
            when {
                expression { return env.INFRA_WAS_STOPPED == 'true' }
            }
            steps {
                sh '''
                    aws ec2 wait instance-status-ok --profile "$AWS_PROFILE" --region "$AWS_REGION" --instance-ids $EC2_INSTANCE_IDS
                    aws rds wait db-instance-available --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID"
                '''
            }
        }

        stage('Discover control-plane IP') {
            steps {
                script {
                    env.CP_HOST = sh(
                        script: 'aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --filters "Name=tag:Name,Values=$CP_TAG_NAME" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PublicIpAddress" --output text',
                        returnStdout: true
                    ).trim()
                }
                echo "control-plane public IP this run: ${env.CP_HOST}"
            }
        }

        stage('Cluster health check') {
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          'kubectl get nodes && kubectl wait --for=condition=Ready nodes --all --timeout=90s' \
                        || {
                            echo "Nodes did not reach Ready within 90s - see output above."
                            echo "If a worker didn't rejoin after the stop/start cycle, the kubeadm join token may have expired:"
                            echo "  ssh $CP_USER@$CP_HOST kubeadm token create --print-join-command"
                            exit 1
                        }
                    '''
                }
            }
        }

        stage('Recreate ecr-registry-key (image pull secret)') {
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          "ECR_REGISTRY='$ECR_REGISTRY' AWS_REGION='$AWS_REGION' bash -s" <<'REMOTE'
                        set -euo pipefail
                        aws ecr get-login-password --region "$AWS_REGION" \
                          | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                        kubectl delete secret ecr-registry-key -n clixx-prod --ignore-not-found
                        kubectl create secret generic ecr-registry-key \
                          --from-file=.dockerconfigjson="$HOME/.docker/config.json" \
                          --type=kubernetes.io/dockerconfigjson \
                          -n clixx-prod
REMOTE
                    '''
                }
            }
        }

        stage('Install Argo CD (skip if already present)') {
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          "ARGOCD_MANIFEST='$ARGOCD_MANIFEST' bash -s" <<'REMOTE'
                        set -euo pipefail
                        if kubectl get namespace argocd >/dev/null 2>&1; then
                            echo "argocd namespace already exists - skipping install."
                        else
                            kubectl create namespace argocd
                            kubectl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_MANIFEST"
                            kubectl -n argocd rollout status deploy/argocd-server
                        fi
REMOTE
                    '''
                }
            }
        }

        stage('Install Argo CD Image Updater (skip if already present)') {
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          "IMAGE_UPDATER_MANIFEST='$IMAGE_UPDATER_MANIFEST' bash -s" <<'REMOTE'
                        set -euo pipefail
                        if kubectl get deployment argocd-image-updater -n argocd >/dev/null 2>&1; then
                            echo "argocd-image-updater deployment already exists - skipping install."
                        else
                            kubectl apply -n argocd --server-side --force-conflicts -f "$IMAGE_UPDATER_MANIFEST"
                        fi
REMOTE
                    '''
                }
            }
        }

        stage('git-creds secret (create if missing)') {
            steps {
                withCredentials([string(credentialsId: 'clixx-gitops-git-pat', variable: 'GIT_PAT')]) {
                    sshagent(credentials: ['clixx-control-plane-ssh']) {
                        sh '''
                            EXISTS=$(ssh $SSH_OPTS "$CP_USER@$CP_HOST" 'kubectl get secret git-creds -n argocd --ignore-not-found -o name')
                            if [ -n "$EXISTS" ] && [ "$RECREATE_GIT_CREDS" != "true" ]; then
                                echo "git-creds already exists - skipping (set RECREATE_GIT_CREDS=true to force-rotate)."
                            else
                                PAT_FILE=$(mktemp)
                                trap 'rm -f "$PAT_FILE"' EXIT
                                umask 077
                                printf '%s' "$GIT_PAT" > "$PAT_FILE"
                                ssh $SSH_OPTS "$CP_USER@$CP_HOST" '
                                    set -euo pipefail
                                    kubectl delete secret git-creds -n argocd --ignore-not-found
                                    kubectl create secret generic git-creds -n argocd \
                                      --from-literal=username=x-access-token \
                                      --from-file=password=/dev/stdin
                                ' < "$PAT_FILE"
                            fi
                        '''
                    }
                }
            }
        }

        stage('ArgoCD repository credential (create if missing)') {
            steps {
                withCredentials([string(credentialsId: 'clixx-gitops-git-pat', variable: 'GIT_PAT')]) {
                    sshagent(credentials: ['clixx-control-plane-ssh']) {
                        sh '''
                            EXISTS=$(ssh $SSH_OPTS "$CP_USER@$CP_HOST" 'kubectl get secret clixx-gitops-repo-creds -n argocd --ignore-not-found -o name')
                            if [ -n "$EXISTS" ] && [ "$RECREATE_GIT_CREDS" != "true" ]; then
                                echo "clixx-gitops-repo-creds already exists - skipping (set RECREATE_GIT_CREDS=true to force-rotate)."
                            else
                                PAT_FILE=$(mktemp)
                                trap 'rm -f "$PAT_FILE"' EXIT
                                umask 077
                                printf '%s' "$GIT_PAT" > "$PAT_FILE"
                                ssh $SSH_OPTS "$CP_USER@$CP_HOST" '
                                    set -euo pipefail
                                    kubectl delete secret clixx-gitops-repo-creds -n argocd --ignore-not-found
                                    kubectl create secret generic clixx-gitops-repo-creds -n argocd \
                                      --from-literal=type=git \
                                      --from-literal=url=https://github.com/eayanwale/clixx-gitops.git \
                                      --from-literal=username=x-access-token \
                                      --from-file=password=/dev/stdin
                                    kubectl label secret clixx-gitops-repo-creds -n argocd argocd.argoproj.io/secret-type=repository --overwrite
                                ' < "$PAT_FILE"
                            fi
                        '''
                    }
                }
            }
        }

        stage('Deploy clixx Application CR (skip if pods already running)') {
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        RUNNING=$(ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          'kubectl get pods -n clixx-prod -l app=clixx-web-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l')
                        if [ "$RUNNING" -gt 0 ]; then
                            echo "clixx-web-app already has $RUNNING pod(s) Running - skipping Application CR apply."
                        else
                            cat apps/clixx-app.yaml | ssh $SSH_OPTS "$CP_USER@$CP_HOST" 'kubectl apply -f -'
                        fi
                    '''
                }
            }
        }

        stage('Force immediate Argo CD sync') {
            steps {

                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" \
                          'kubectl -n argocd annotate application clixx argocd.argoproj.io/refresh=hard --overwrite'
                    '''
                }
            }
        }

        stage('Force fresh pods (stale DB connections + expired ECR auth)') {
            when {
                expression { return env.INFRA_WAS_STOPPED == 'true' }
            }
            steps {
                sshagent(credentials: ['clixx-control-plane-ssh']) {
                    sh '''
                        ssh $SSH_OPTS "$CP_USER@$CP_HOST" '
                            set -euo pipefail
                            kubectl delete pods -n clixx-prod -l app=clixx-web-app --ignore-not-found
                            kubectl -n clixx-prod rollout status deployment/clixx-web-deployment --timeout=180s
                        '
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "ArgoCD UI access, if needed: SSH tunnel with 'ssh -L 8080:localhost:8080 ${env.CP_USER}@${env.CP_HOST}', then on that same box run 'kubectl -n argocd port-forward svc/argocd-server 8080:443', then open https://localhost:8080 locally."
            echo "MCP server re-registration (control-plane IP may have changed): claude mcp remove ${env.MCP_NAME} 2>/dev/null; claude mcp add --transport stdio ${env.MCP_NAME} -- ssh -o BatchMode=yes ${env.CP_USER}@${env.CP_HOST} ${env.MCP_VENV_PYTHON} ${env.MCP_SERVER_PATH}"
            slackSend(
                channel: '#stackjenkins',
                color: 'good',
                message: "SUCCESS: ${env.JOB_BASE_NAME} #${env.BUILD_NUMBER} (${env.BUILD_URL})"
            )
        }
        failure {
            slackSend(
                channel: '#stackjenkins',
                color: 'danger',
                message: "FAILED: ${env.JOB_BASE_NAME} #${env.BUILD_NUMBER} (${env.BUILD_URL})"
            )
        }
    }
}
