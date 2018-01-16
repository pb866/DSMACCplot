__precompile__()


"""
# Module jlplot

Define type of plots and species/reactions to be plotted from an input file.
Generate arrays with names of DSMACC netCDF files, scenario names,
species/reactions to be plotted and further indices needed for the processing
of the data.


# Public functions

- commission_plot
- get_scenario
- get_settings
- prepare_plots
- DSMACCoutput
- get_stackdata
"""
module jlplot


##################
###  PREAMBLE  ###
##################

# Export public functions
export commission_plot,
       get_scenario,
       get_settings,
       prepare_plots,
       DSMACCoutput,
       get_stackdata

# Find directory of module source code
cdir=Base.source_dir()

# Loading external and internal self-made modules
# Define directory of modules in main script
# (absolute or relative paths to location, where main script is called)
# Local Mac:
if isdir("/Applications/bin/data/jl.mod") &&
  all(LOAD_PATH.!="/Applications/bin/data/jl.mod")
  push!(LOAD_PATH,"/Applications/bin/data/jl.mod")
end
# earth0:
if isdir("~/Util/auxdata/jl.mod") &&
  all(LOAD_PATH.!="~/Util/auxdata/jl.mod")
  push!(LOAD_PATH,"~/Util/auxdata/jl.mod")
end
# Current directory
if all(LOAD_PATH.!=cdir)  push!(LOAD_PATH,cdir)  end

using fhandle
using NCload
using DataFrames


##########################
###  PUBLIC FUNCTIONS  ###
##########################

"""
    commission_plot(ifile::String="plot.inp")

Read input file `ifile` and return Array with lines `commission` as well as
indices for the beginning of the scenario section `scen`, the beginning of the
settings sections `sett`, and the beginning and end of the plotting section
`beg_plt` and `end_plt`.
"""
function commission_plot(ifile::String="plot.inp")
  # Assume either DSMACC main folder or DSMACC/AnalysisTools/DSMACCanalysis
  # as current directory, other wise add/adjust folder path here:
  if splitdir(pwd())[2] == "DSMACCanalysis"  def_dir = "."
  else def_dir = "./AnalysisTools/DSMACCanalysis"
  end
  # Read and store lines from input file
  commission = rdinp(ifile, default_dir=def_dir)
  # Remove comments in file content
  for i = length(commission):-1:1
    if startswith(commission[i],"#")  deleteat!(commission,i)
    else try
      commission[i] = replace(commission[i],match(r"#.*",commission[i]).match,"")
    end end
  end

  # Find indices for beginning of scenario definitions
  # and beginning/end of plotting section
  scen = find([contains(line,"Scenarios:") for line in commission])[1] + 1
  sett = find([contains(line,"Settings:") for line in commission])
  beg_plt = find([contains(line,"Plotting:") for line in commission])[1] + 1
  end_plt = find([contains(line,"Comments:") for line in commission])
  # Correct end of plotting section if not followed by Comments section
  if isempty(sett)  sett = 0
  else              sett = sett[1] + 1
  end
  # Correct end of plotting section if not followed by Comments section
  if isempty(end_plt)
    end_plt = length(commission)
  else
    end_plt = end_plt[1] - 1
    commission = commission[1:end_plt]
  end
  # Compile indices in an array
  fidx = [scen, sett, beg_plt, end_plt]

  # Remove blank lines (whitespaces allowed) between section headings
  # and first content line
  commission, fidx = rm_blanklines(commission,fidx)

  # Return file content and indices
  return commission, fidx
end #function commission_plot


"""
    get_scenario(lines,strt)

From `lines` in input file and index `strt` for beginning of the Scenario section,
retrieve and return arrays `ncfile` and `label` with the directory and name of the
DSMACC netCDF files and names for the respective scenarios.

If no scenario names are specified, the netCDF file names without the extension
will be used.
"""
function get_scenario(lines,strt)

  # Get nc file names
  lines[strt] = replace(lines[strt],r",|;"," ") # allow other separators than spaces
  ncfile = split(lines[strt])

  # Get scenario names
  label = String[]
  if lines[strt+1]==""
    # Get scenario names from file names, if no labels are given in input file
    for scen in ncfile  push!(label,basename(splitext(scen)[1]))  end
  else
    # Read scenario names from file (labels must be wrapped in double quotes)
    s = Int64[]; si = 1
    for i = 1:length(ncfile)*2
      push!(s,searchindex(lines[strt+1],"\"",si))
      si = s[end] + 1
    end
    for i = 1:2:length(ncfile)*2
      push!(label,lines[strt+1][s[i]+1:s[i+1]-1])
    end
  end

  # Error handling
  if length(label) != length(ncfile)
    # Stop if number of labels is unequal to number of nc files
    println("There must be exactly as much labels define in the input file as nc file")
    println("or no labels at all. (Don't use double quotes in labels.) Script stopped.")
    exit()
  end
  for lab in label
    # Stop if duplicate labels are defined
    len = length(find(s==lab for s in label))
    if len > 1  println("Error: Non-unique labels! Script stopped."); exit()  end
  end

  # Return arrays with file names and labels
  return ncfile, label
end #function get_scenario


"""
    get_settings(lines,sett_idx)

From the `lines` in the input plot file and the index for the start of the
settings section in the lines `sett_idx`, find and return the lower and upper
cut-off parameters for minor/major fluxes and the switch to calculate (or not)
net cycles of chemical fluxes or return the default values of llim = 0.05,
ulim = 0.7, and cycles = "reduce".
"""
function get_settings(lines,sett_idx)

  # Set default cut-off parameters
  llim = 0.05
  ulim = 0.7
  cycles = "reduce"
  # Overwrite parameters with values from the Settings section, if defined
  if sett_idx!=0
    i = sett_idx
    while lines[i] != ""
      if lines[i][1:8]=="cut-off:"
        lines[i] = replace(lines[i],r",|;"," ") # allow other separators than spaces
        llim, ulim = float.(split(lines[i][9:end]))
      elseif lines[i][1:7]=="cycles:"
        cycles = strip(lines[i][8:end])
      end
      i += 1
    end
  end

  # Return lower and upper cut-off
  return llim, ulim, cycles
end #function get_settings


"""
    prepare_plots(commission,label)

From the plotting section of the input file `commission` and the `label`s of
each scenario, retrieve the index `icase` of the scenario to plot, `what` to
plot (species concentrations/reaction rates/fluxes) and the `plotdata` with the
species/reactions that go into each plot.
"""
function prepare_plots(commission,label)

  # Initilise
  new_case = true
  icase = []
  what = []
  unit = []
  plotdata = []
  pdata = []
  # Loop over plotting section of input file
  for (i, line) in enumerate(commission)
    if line == "" && commission[i-1]==""
      continue
    elseif line == ""
      # On empty lines, reset flag for new case, collect current plot data in array
      # and reset temporary memory for plot data
      new_case = true
      push!(plotdata,pdata)
      pdata = []
    elseif new_case
      # First line or lines after empty lines look for plot type definition
      new_case = false #set flag for new case to false
      # split line into pre- and post-colon
      icol = searchindex(line,":")
      # Get post-colon data and save what to plot (concentrations/rates) and units
      wh = ""; un = ""
      try wh, un = split(line[icol+1:end],"/")
      catch
        # If units are obsolete, use mlc·cm-3 (s-1) as default
        wh = strip(line[icol+1:end])
        un = "mlc"
      end
      push!(what,strip(wh)); push!(unit,strip(un))

      # Look for the scenarios to plot before the colon
      # Read scenario labels
      idx = Int64[]
      line = replace(line,r",|;"," ") # allow other separators than spaces
      lab = split(line[1:icol-1])
      # Get indices of each scenario
      for l in lab
        ic = find(s==l for s in label)[1]
        push!(idx, ic)
      end
      # save indices in array icase
      push!(icase,idx)
    else
      # Save array with species/reactions to be plotted to array plotdata
      # when reading general data lines
      # Allow commas, semicolons or whitespace as separator
      line = replace(line,r",|;"," ")
      push!(pdata,strip.(split(line)))
    end
  end

  # Return final arrays
  return icase, what, unit, plotdata
end #function prepare_plots


"""
    DSMACCoutput(ncfiles)

Compile data of netCDF files in Julia readable formats.

Data will be stored in a dictionary distinguishing between `"specs"` and `"rates"`,
each holding an array of dataframes with data from the `ncfiles` from each scenario
compiled in the array and the different species concentrations/reaction rates
compiled in the dataframes.

The function also calculates the model time starting with `0` at the beginning of the
model run and stores an array in the dictionary entry `"time"`.
"""
function DSMACCoutput(ncfiles)

  # Assume either DSMACC main folder or DSMACC/AnalysisTools/DSMACCanalysis
  # as current directory, other wise add/adjust folder path here:
  if splitdir(pwd())[2] == "DSMACCanalysis"  def_dir = "../../save/results"
  else def_dir = "./save/results"
  end

  # Loop over all nc file, check for existance and read content
  # separately for species concentrations and reaction rates
  spec = []; rate = []
  for ncfile in ncfiles
    # Assign default path, if no path is specified for the nc files
    if dirname(ncfile)==""  ncfile = normpath(joinpath(def_dir,ncfile))  end
    # Read species concentrations/reaction rates of current nc file
    spc, rat = get_ncdata(ncfile)
    # Save concentrations/rates in array with all scenarios
    push!(spec,spc); push!(rate,rat)
  end

  # Calculate model time starting at 0, from the time step of the last 2 model times
  dt = spec[1][end,:TIME]-spec[1][end-1,:TIME]
  t = 0; time = Float64[]
  for i = 1:length(spec[1][:,:TIME])
    push!(time, t/3600); t += dt
  end

  # Return dictionry with model time, and concentrations/rates of all scenarios
  return data = Dict("time"=>time, "specs"=>spec, "rates"=>rate)
end #function DSMACCoutput


"""
    get_stackdata(spc_list,case,ydata,unit)

Plot the concentrations of the species in `spc_list` for the current `case` using
the `ydata` in the specified `unit` and return y data in the correct unit for the
boundaries and the areas in the graph.
"""
function get_stackdata(spc_list,case,ydata,unit)
  # Initialise output arrays
  ystack = DataArray[]; ylines = DataArray[]
  # Define areas for stack plot
  for spc in spc_list
    push!(ystack,ydata[case][Symbol(spc)])
  end
  # Define boundary lines for stack plot
  for i = 1:length(ystack)
    push!(ylines,sum(ystack[1:i]))
  end

  # Perform unit conversions
  if unit=="ppm"
    for l = 1:length(ylines)
      ylines[l] .*= 1.e6./ydata[case][:M]
      ystack[l] .*= 1.e6./ydata[case][:M]
    end
  elseif unit=="ppb"
    for l = 1:length(ylines)
      ylines[l] .*= 1.e9./ydata[case][:M]
      ystack[l] .*= 1.e9./ydata[case][:M]
    end
  elseif unit=="ppt"
    for l = 1:length(ylines)
      ylines[l] .*= 1.e12./ydata[case][:M]
      ystack[l] .*= 1.e12./ydata[case][:M]
    end
  end

  # Return boundaries and areas to be plotted over time
  return ylines, ystack
end


###########################
###  PRIVATE FUNCTIONS  ###
###########################

"""
    rm_blanklines(lines,idx)

Starting at index `idx` in the string array `lines` remove all blank lines
until the first line with non-whitespace characters is found.
"""
function rm_blanklines(lines,idx)
  # Loop over different sections
  for i = length(idx)-1:-1:1
    # Skip for missing 2nd section
    if idx[i] == 0  continue  end
    # Delete leading blank lines until first line with content is found
    while strip(lines[idx[i]])==""
      deleteat!(lines,idx[i])
      idx[i+1:end] -= 1
    end
  end
  # Revert index correction for missing second section
  idx[2] = max(0,idx[2])

  # Return adjusted array with lines
  return lines, idx
end #function rm_blanklines

end #module jlplot