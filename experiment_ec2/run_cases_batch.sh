SERVICE="carts"
FAULT_INJECTION_TYPE="cpu"  
RANDOM_START_TIME=$(shuf -i 300-1080 -n 1) 

for i in {1..3}
do
   echo "Running ${FAULT_INJECTION_TYPE} case to ${SERVICE} service #$i"
   #bash run_pipeline.sh -t ${SERVICE} -f ${FAULT_INJECTION_TYPE}
   bash run_pipeline_ad.sh -t ${SERVICE} -f ${FAULT_INJECTION_TYPE} -d 120s --inject-start $RANDOM_START_TIME
   sleep 12m
done