pipeline {
    agent any

    parameters {
        // Environment name is passed to the monitoring agents (Filebeat adds it to every
        // log event as "environment"), so the same pipeline can deploy lab/staging/prod
        choice(name: 'DEPLOY_ENV', choices: ['lab', 'staging', 'production'], description: 'Environment label for monitoring agents')
    }

    environment {
        REGISTRY   = '192.168.56.15:5000'
        APP_SERVER = '192.168.56.13'
        WEB1       = '192.168.56.11'
        WEB2       = '192.168.56.12'
        MONITORING = '192.168.56.16'
        SSH_KEY    = '/var/lib/jenkins/.ssh/id_ed25519'
        // accept-new: trust a host key on first connect (monitoring-server boots after
        // ci-server, so it is not in known_hosts yet), but fail if a known key changes
        SSH_OPTS   = '-i /var/lib/jenkins/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30'
        // every VM that runs the monitoring agents: ip=hostname
        MONITORED_HOSTS = '192.168.56.10=load-balancer 192.168.56.11=web-server-1 192.168.56.12=web-server-2 192.168.56.13=app-server 192.168.56.14=backup-server 192.168.56.15=ci-server 192.168.56.16=monitoring-server'
        LOGSTASH_HOST   = '192.168.56.16'
    }

    stages {

        stage('Build') {
            steps {
                sh 'docker build -t $REGISTRY/backend:latest ./backend'
                sh 'docker build -t $REGISTRY/frontend:latest ./frontend'
            }
        }

        stage('Push') {
            steps {
                sh 'docker tag $REGISTRY/backend:latest $REGISTRY/backend:$BUILD_NUMBER'
                sh 'docker tag $REGISTRY/frontend:latest $REGISTRY/frontend:$BUILD_NUMBER'
                sh 'docker push $REGISTRY/backend:latest'
                sh 'docker push $REGISTRY/backend:$BUILD_NUMBER'
                sh 'docker push $REGISTRY/frontend:latest'
                sh 'docker push $REGISTRY/frontend:$BUILD_NUMBER'
            }
        }

        stage('Deploy backend') {
            steps {
                sh '''
                    ssh -i $SSH_KEY devops@$APP_SERVER \
                    "docker pull $REGISTRY/backend:latest && \
                     docker compose -f /vagrant/docker-compose.backend.yml up -d"
                '''
            }
        }

        stage('Deploy frontend') {
            steps {
                sh '''
                    ssh -i $SSH_KEY devops@$WEB1 \
                    "docker pull $REGISTRY/frontend:latest && \
                     docker compose -f /vagrant/docker-compose.frontend.yml up -d"

                    ssh -i $SSH_KEY devops@$WEB2 \
                    "docker pull $REGISTRY/frontend:latest && \
                     docker compose -f /vagrant/docker-compose.frontend.yml up -d"
                '''
            }
        }

        stage('Deploy monitoring stack') {
            steps {
                // Prometheus targets, alert rules, dashboards, Logstash pipeline live in git:
                // sync them to monitoring-server and apply
                sh '''
                    rsync -az --delete --exclude agents/ --exclude .env \
                        -e "ssh $SSH_OPTS" monitoring/ devops@$MONITORING:/home/devops/monitoring/
                    ssh $SSH_OPTS devops@$MONITORING \
                    "cd /home/devops/monitoring && \
                     docker compose up -d --quiet-pull --remove-orphans && \
                     curl -fsS -X POST http://localhost:9090/-/reload && \
                     docker compose restart grafana"
                '''
            }
        }

        stage('Deploy monitoring agents') {
            steps {
                // Same agents everywhere; only .env differs per host / per environment
                sh '''
                    # the very first build after adding the parameter runs without it
                    deploy_env=${DEPLOY_ENV:-lab}
                    for target in $MONITORED_HOSTS; do
                        ip=${target%%=*}
                        name=${target#*=}
                        echo "==> monitoring agents on $name ($ip), environment=$deploy_env"
                        rsync -az --delete --exclude .env \
                            -e "ssh $SSH_OPTS" monitoring/agents/ devops@$ip:/home/devops/monitoring-agents/
                        printf 'HOST_NAME=%s\\nENVIRONMENT=%s\\nLOGSTASH_HOST=%s\\nLOGSTASH_PORT=5044\\n' \
                            "$name" "$deploy_env" "$LOGSTASH_HOST" \
                            | ssh $SSH_OPTS devops@$ip "cat > /home/devops/monitoring-agents/.env"
                        ssh $SSH_OPTS devops@$ip \
                        "cd /home/devops/monitoring-agents && \
                         docker compose up -d --quiet-pull --remove-orphans && \
                         docker compose restart filebeat"
                    done
                '''
            }
        }

        stage('Smoke Test') {
            steps {
                sh 'sleep 10'
                sh 'curl -f --max-time 10 http://$APP_SERVER:3001/metrics || (echo "Backend health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://192.168.56.10 || (echo "Load balancer health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://$WEB1 || (echo "Web server 1 health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://$WEB2 || (echo "Web server 2 health check failed" && exit 1)'
                sh 'curl -fs --max-time 10 http://$APP_SERVER:3001/prometheus | grep -q infra_metrics_served_total || (echo "Backend Prometheus endpoint check failed" && exit 1)'
                sh 'curl -fs --max-time 10 http://$MONITORING:9090/-/ready || (echo "Prometheus check failed" && exit 1)'
                sh 'curl -fs --max-time 10 http://$MONITORING:3000/api/health || (echo "Grafana check failed" && exit 1)'
                // how many targets of each job Prometheus can scrape right now
                sh 'curl -fs --max-time 10 http://$MONITORING:9090/api/v1/query --data-urlencode "query=sum by (job) (up)"; echo'
                echo 'All smoke tests passed'
            }
        }
    }

    post {
        success {
            sh '''
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] BUILD #$BUILD_NUMBER SUCCESS - all stages passed, app is live" \
                >> /var/log/jenkins-notifications.log
            '''
        }
        failure {
            sh '''
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] BUILD #$BUILD_NUMBER FAILED - check console: http://192.168.56.15:8080/job/infra-insight/$BUILD_NUMBER/console" \
                >> /var/log/jenkins-notifications.log
            '''
        }
        always {
            sh 'tail -5 /var/log/jenkins-notifications.log'
        }
    }
}
