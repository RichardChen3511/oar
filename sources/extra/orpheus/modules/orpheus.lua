--
--[[
SIGUSR1 signal triggers the get to 

Features no supported
 - Interactive Job
 - Killing job
 - Best effort (side effect of killing job capacity)
 - Resource / Job Fault

TODO:
* Pour le kill: le plus simple proposer une alternative de 
signal_oarexec($$$$$$$) dans OAR::Tools.pm et modifier leon.pl pour l'appeler
(masquable dynamiquement ???)

* doc command options in orpheus.rst
* walltime (optional) only command !
* install/uninstall script 
* arg (walltime)
* Readme
* Kill job
* tests (à la oar_api rspec) ???
* kameleon step

I/O contention/perturbation simulation

Pseudo algorithm:
 at each job starting or terminating events do
  compute new global I/O contention
  compute new remaing work and terminating time for each I/O jobs
 end
]]--

require "oar"
require "socket"
require "signal"

-- some globals
chronos = {} -- array to keep end of execution time of jobs 
io_jobs = {} -- tables of job with io activities
terminated_io_jobs = {} -- to keep trace of already terminated io_jobs
io_model = "linear" -- NOT USED YET, in the eventually of mutiple io models
io_capacity = 10 -- TODO: option argument ???
io_workload = 0 -- current global io workload
next_io_workload = 0  -- to store the next io_worload value due to new or terminated io jobs 
                      -- (simple model constant io workload per job)

oar.conf_load()
con = oar.connect()

default_walltime  = 10

tmp_job = {} -- store temparaly job's parameter/desciption from oar's db

t0 = os.time()

n_last = 1 -- os.time - os.time() + 1 (for chronos indice)
nb_launched_jobs = 0
nb_terminated_jobs = 0
nb_received_signals =0
nb_get_jobs = 0

if not oar.conf["SERVER_HOSTNAME"] then
  almighty_host = 'localhost'
else
  almighty_host = oar.conf["SERVER_HOSTNAME"]
end

if not oar.conf["SERVER_PORT"] then
  almighty_port = 6666
else
  almighty_port = oar.conf["SERVER_PORT"]
end

-- signal handler function use to notify orpheus that there are jobs to run
signal.signal("SIGUSR1", 
    function(n, i) 
      print("signal handler", n, i) 
      nb_received_signals = nb_received_signals +1
    end);

-- get pid of current orpheus process
function getpid()
  local fproc = io.open("/proc/self/stat","r")
  return oar.wssplit(fproc:read("*l"))
end

-- create the orpheus signal sender 
function create_signal_sender()
  local pid = getpid()
  os.execute("rm -f /tmp/orpheus_signal_sender; echo 'kill -s USR1 " .. pid .."' > /tmp/orpheus_signal_sender; chmod 755 /tmp/orpheus_signal_sender;")
end

-- get job to launch + set running + insert in chronos
function get_jobs()
  local job_ids = ""
  local execution_time = default_walltime
  local delta_io_workload = 0 -- io_worload evolution due to new or terminated jobs
  local new_io_jobs = false
  local ts = os.time() - t0 -- orpheus start_time for this get jobs cycle 
                            -- be carefull of SQL processing time it'll include in global time job execution 
  for row in oar.rows("SELECT job_id, command from jobs WHERE state='toLaunch'") do
    local job = {}
    job_id = row[1]
    print(job_id)
    job_ids = job_ids .. job_id .. ','
    -- determine the execution time 
    if row[2] then
      -- options is set as valid lua table in place cli argument testio {exec_time=1234,io=1,io_workload=1, io_sensivity=1 ...} 
      local f,l,opts = string.find(row[2], ".%S+%s(.*)")
      if opts then
        print("OPTS: "..opts)
        assert(loadstring("tmp_job = " .. opts))()
        --assert(loadstring("tmp_job =".."{exec_time=5}"))()
        job = oar.deepcopy(tmp_job)
        if job.exec_time then 
          execution_time = job.exec_time
        end
      end
    end
    
    --  this job is one with I/O requirements
    if job.io then
      new_io_jobs = true
      --   ad to I/O list job
      io_jobs[job_id] = job
      io_jobs[job_id].t_prev = ts -- save time where work and io perturbation have been updated 
      io_jobs[job_id].work = 0 -- work which had been executed (normalized to 1 unit per second) 
      -- add job's I/O workload contribution 
      delta_io_workload = delta_io_workload + job.io_workload 
    else
      local i = ts + execution_time
      if not chronos[i] then chronos[i] = {} end -- initialize slot end_time if needed
      -- job id insert in slot end_time
      chronos[i][#chronos[i]+1] = job_id
    end

    nb_launched_jobs = nb_launched_jobs + 1
    
  end
  job_ids = string.sub(job_ids, 1, -2) --chomp the last ','

  if new_io_jobs then
    print("new_io_jobs")
    -- update next io_workload
    next_io_workload = io_workload + delta_io_workload 
    update_io_jobs_execution_time()
  end 

  -- set job running
  -- p = "UPDATE jobs SET state='Running' WHERE job_id IN "..jobids
  -- print(p)i
  oar.sql("UPDATE jobs SET state='Running' WHERE job_id IN ("..job_ids..')')
end

function update_io_jobs_execution_time()
  tc = os.time() - t0
  print("update_io_job")
  print("io_workload: ".. io_workload)
  print("next_io_workload: ".. next_io_workload)

  for j_id,job in pairs(io_jobs) do

    print("io_jobid: "..j_id)
    
    -- for linear model
    local executed_work = (tc - job.t_prev)
    job.t_prev = tc -- for the next compute of executed work step

    -- proportional slowdown if io_workload had exceeded IO system's capacity
    if io_workload > io_capacity then 
      executed_work = executed_work * (io_capacity / io_workload) 
    end
    job.work = job.work + executed_work -- update executed work
    

    -- compute new ending time 
    local new_remaning_time = job.exec_time - job.work
    if next_io_workload > io_capacity then
      new_remaning_time = (job.exec_time - job.work) * (next_io_workload / io_capacity)
    end

    print("remainng time:".. new_remaning_time)

    if new_remaning_time > 0 then -- new insert in chronos old one will be ignored at expiration time  
      local i =  new_remaning_time + tc
      if not chronos[i] then chronos[i] = {} end -- initialize slot end_time if needed
      chronos[i][#chronos[i]+1] = j_id
      job.ending_time = i -- used to test the job's ending
    else
      -- TODO Do we have a trouble ?
      print("warning (new_remaning_time =< 0) something dirty is happen with iojob: "..j_id)
    end
  end
  io_workload = next_io_workload
end

function terminated_jobs()
  local delta_io_workload = 0 -- io_worload evolution due to new or terminated jobs
  local n1 = os.time() - t0
  local terminated_jobs = 0
  local terminated_job_ids = ""
  for i=n_last,n1 do
    local io_jobs_terminated = false
    if chronos[i] then
      for k,j_id in ipairs(chronos[i]) do
        if io_jobs[j_id] then
          local job = io_jobs[j_id]
          -- io job terminated
          if (i == job.ending_time) then
            io_jobs_terminated = true
            -- remove job's io_workload 
            delta_io_workload = delta_io_workload - job.io_workload
            io_jobs[j_id] = nil -- remove io_job from the list
            print("terminated io_job_id: ",j_id,"i:",i)
            terminated_job_ids = terminated_job_ids  .. j_id .. ','
            terminated_jobs = terminated_jobs + 1

            terminated_io_jobs[j_id] = true
          end
        else
          if not terminated_io_jobs[j_id] then
            print("terminated job_id: ",j_id,"i:",i)
            terminated_job_ids = terminated_job_ids  .. j_id .. ','
            terminated_jobs = terminated_jobs + 1
          end
        end
      end
      chronos[i] = nil --bye bye job_ids 
    end
    if io_jobs_terminated then 
      -- update next io_workload
      next_io_workload = io_workload + delta_io_workload
      print ("iow,n_iow,d_iow", io_workload, next_io_workload, delta_io_workload)
      update_io_jobs_execution_time()
    end
  end
  n_last = n1
  if terminated_jobs ~= 0 then
    nb_terminated_jobs = nb_terminated_jobs + terminated_jobs

    terminated_job_ids = string.sub(terminated_job_ids, 1, -2) --chomp the last ','
    -- update jobs oar db table and set stop time ??
    oar.sql("UPDATE jobs SET state='Terminated',stop_time='"..t0+n1.."' WHERE job_id IN ("..terminated_job_ids..")")
    -- send Scheduling command to almighty
    notify_almighty()
  end
end

-- notify jobs' termination
function notify_almighty()
  local client = socket.connect(almighty_host,almighty_port)
  client:send("Scheduling\n")
  client:close()
end

-- main loop
socket.select(nil,nil,1)
-- create orpheus_signal_sender (runner moduler must be a symlink to it)
create_signal_sender()

--oar.set_all_jobs_toLaunch() -- only for dev and debug
--get_jobs()

-- select
k = 0
while true do

  socket.select(nil,nil,1)

  if (nb_received_signals > nb_get_jobs) then
--    set_all_jobs_toLaunch() -- ONLY for dev and debug
    get_jobs()
    nb_get_jobs = nb_received_signals 
  end

  terminated_jobs()
  if (k % 10) == 0 then
    print('=========================================================================')
    print("nb_jobs launched:", nb_launched_jobs, 
          "terminated: ", nb_terminated_jobs , 
          "running: ", nb_launched_jobs-nb_terminated_jobs,
          "\nnb_recv_signal/nb_get_jobs", nb_received_signals, nb_get_jobs,
          "\nio_workload: ", io_workload)
    print('=========================================================================')
  end
  k = k +1
end

con:close()
env:close()
