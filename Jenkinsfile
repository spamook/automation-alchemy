pipeline {
    agent any

    environment {
        REGISTRY   = '192.168.56.15:5000'
        APP_SERVER = '192.168.56.13'
        WEB1       = '192.168.56.11'
        WEB2       = '192.168.56.12'
        SSH_KEY    = '/var/lib/jenkins/.ssh/id_ed25519'
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

        stage('Smoke Test') {
            steps {
                sh 'sleep 10'
                sh 'curl -f --max-time 10 http://$APP_SERVER:3001/metrics || (echo "Backend health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://192.168.56.10 || (echo "Load balancer health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://$WEB1 || (echo "Web server 1 health check failed" && exit 1)'
                sh 'curl -f --max-time 10 http://$WEB2 || (echo "Web server 2 health check failed" && exit 1)'
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