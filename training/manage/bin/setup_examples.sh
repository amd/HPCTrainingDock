#!/bin/sh

cd /Shared
sudo chmod 777 /Shared
sudo chgrp hackathon /Shared
git clone https://github.com/AMD/HPCTrainingExamples
git clone https://github.com/joelandman-amd/rzf_training
sudo chgrp -R hackathon /Shared
chmod -R g+rw /Shared
chmod -R o+rw /Shared
#chgrp -R hackathon /Shared/HPCTrainingExamples
#chmod -R 755 /Shared/HPCTrainingExamples
