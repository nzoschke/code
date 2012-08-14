# Code

## Getting started

```bash
git clone https://github.com/nzoschke/code.git

bundle install

bin/virtualenv venv
venv/bin/pip install --requirement=requirements.txt
source venv/bin/activate

cp env.sample .env

foreman start

git push http://localhost:5200/gentle-snow-22.git master
git push  ssh://localhost:5400/gentle-snow-22.git master
```
