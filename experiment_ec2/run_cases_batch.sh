SERVICE="carts"
FAULT_INJECTION_TYPE="cpu"  

for i in {1..3}
do
   echo "Running ${FAULT_INJECTION_TYPE} case to ${SERVICE} service #$i"
   bash run_pipeline.sh -t ${SERVICE} -f ${FAULT_INJECTION_TYPE}
   sleep 12m
done