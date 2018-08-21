git config --global user.name "Agasse Hervé"
git config --global user.email "herve.agasse@orange.com"

git clone https://gitlab.forge.orange-labs.fr/dixsiptal/Deploy_mongodb.git
cd Deploy_mongodb
touch README.md
git add README.md
git commit -m "add README"
git push -u origin master

