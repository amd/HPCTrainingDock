BEGIN {
        cpus=0
	threads=0
	cores=0
	sockets=0
	mi210=0
	mi250=0
	mi100=0
	memory=0
      }
# lscpu > cpu.out
/^CPU\(s\)/            { cpus = $2 }     
/^Thread\(s\) per core/  { threads = $4 }
/^Core\(s\) per socket/  { cores = $4 } 
/^Socket\(s\)/         { sockets = $2 } 
/AMD Instinct MI210/     { mi210 = mi210+1 }
/AMD Instinct MI250/     { mi250 = mi250+1 }
/AMD Instinct MI100/     { mi100 = mi100+1 }
# note memory is by G (GB) but we need M (MB) so that is what this does, but leave some for the O/S 
/Total online memory/  { memory= $4; split(memory, a, "G"); memory=(a[1]*0.90)*1024 }

END {
     # only supporting one gpu model at a time..unclear how to code for multiple gpu models on the same machine	
     gres="gpu:MI50:0"  # use a valid but not used default

     if ( mi100 > 0) 
     {
	 gres="gpu:MI100:" mi100 " " 
     }

     if ( mi210 > 0) 
     {
	 gres="gpu:MI210:" mi210 " " 
     }

     if ( mi250 > 0) 
     {
	 gres="gpu:MI250:" mi250 " " 
     }


     print ("NodeName=localhost "  \
	    "CPUs=" cpus " " \
	    "RealMemory=" memory "  State=UNKNOWN " \
	    "Gres=" gres " " \
	    "CoresPerSocket=" cores " " \
	    "ThreadsPerCore=" threads " " \
	    "SocketsPerBoard=" sockets " " \
	    "Feature=HyperThread " \
           )

    }

