set -x
echo "# DEPLOY_MONGODB_BASH" >> README.md
git config --global user.email "herve.agasse@orange.com"
git init
git add README.md
git commit -m "first commit"
git remote add origin https://github.com/cheucheu/DEPLOY_MONGODB_BASH.git
git push -u origin master
