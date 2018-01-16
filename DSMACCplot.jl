#!/usr/local/bin/julia


"""
# Module DSMACCplot

Use DSMACC dictionary with netCDF data to plot species concentrations
and/or reaction rates for specified species/reactions and netCDF files.

If input file asks for flux plots, perform ROPA analysis and print time-resolved
sink and source analysis plots.

Group species according to the following properties, which can be outputted in
stacked area or line plots:
- Molecule's size
- Chromophore class
- O:C ratio
"""
module DSMACCplot


##################
###  PREAMBLE  ###
##################

println("initialise...")
# Define location of external self-made modules
# (Add or modify to include your own directories)
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

# Add path of internal self-made modules
mdir = joinpath(Base.source_dir(),"jl.mod")
rdir = joinpath(Base.source_dir(),"jl.mod/ropa")
if all(LOAD_PATH.!=mdir)  push!(LOAD_PATH,mdir)  end
if all(LOAD_PATH.!=rdir)  push!(LOAD_PATH,rdir)  end

# Load modules/functions/python libraries
using PyPlot, PyCall, DataFrames
import make_plots
using groupSPC
using jlplot
using ropa_tool, plot_ropa

# Load python function for multiple plots in one pdf
@pyimport matplotlib.backends.backend_pdf as pdf

# Define the netCDF file(s) from the first script argument
# For several files, use list of whitespace separated files wrapped in double quotes
for i = 1:2-length(ARGS)  push!(ARGS,"")  end

#––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––#

#####################
###  MAIN SCRIPT  ###
#####################

println("load data...")
# Read input file
commission, fidx = commission_plot(ARGS[1])
# Get nc file names and scenario names
ncfiles, label = get_scenario(commission,fidx[1])
# Set cut-off for flux plots and switch to calculate inorganic net cycles
llim, ulim, cycles = get_settings(commission,fidx[2])
# Read from input file, which plots to generate
icase, what, unit, plotdata = prepare_plots(commission[fidx[3]:fidx[4]], label)
# Save DSMACC output using a python script to read nc files and save in Julia format
output = DSMACCoutput(ncfiles)
# Data is store in a dictionary distinguishing between "specs" and "rates"
# In each dictionary entry is is an array for each scenario (nc file)
# with dataframes for the respectives species concentrations or reaction rates

if any(what.=="fluxes")
  # Perform ROPA analysis for flux plots
  sources, sinks, concs = ropa(cycles=cycles, specs=output["specs"], rates=output["rates"])
  # Combine species for flux plots in single vector
  for i = 1:length(what)
    if what[i] == "fluxes"
      pldata = String[]
      for j = 1:length(plotdata[i])  for spc in plotdata[i][j]
        push!(pldata,spc)
      end  end
      plotdata[i] = pldata
    end
  end
end

#––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––#

println("analyse data...")
# Load database with different species names
dbfile = normpath(joinpath(Base.source_dir(),"DATA/MCMv331species.db"))
spcDB = readDB(dbfile)
# Translate species names from MCM to GECKO-A
gspc = translateNMVOC(output["specs"],spcDB)
# Group species by properties
CC, OC, CN, chrom_class, OCratio_class, size_class = group_specs(gspc,spcDB)
# Add new classes to dataframes
output["specs"] = add_conc(output["specs"],chrom_class,OCratio_class,size_class,CC,OC,CN)

#––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––#

println("plot data...")
# Define output file name
if ARGS[2] == ""  ARGS[2] = join(label,"_")  end
pdffile = pdf.PdfPages(ARGS[2]*".pdf")

# Loop over different plot types
for n = 1:length(icase)
  if what[n]=="fluxes"
    # Loop over species and scenarios for flux plots
    for spc in plotdata[n]  for case in icase[n]
      # Load plot data from ropa analysis
      modtime, src, snk, src_rev, snk_rev =
        load_plotdata(spc,case,sources,sinks,concs,label,llim=llim,ulim=ulim)
      # Output flux plots
      fig = plot_data(spc,label[case],modtime,src,snk)
      if fig != nothing  pdffile[:savefig](fig)  end
      # if fig != nothing  fig[:show]()  end
      # Output revised flux plots, if major fluxes have been removed
      fig = plot_data(spc,label[case],modtime,src_rev,snk_rev)
      if fig != nothing  pdffile[:savefig](fig)  end
      # if fig != nothing  fig[:show]()  end
      # input("Next picture?")
    end  end
  elseif what[n]=="stack"
    colstyle = ["source","sink"]
    # Plot stack plots of species concentrations for all cases
    for spc in plotdata[n]  for i = 1:length(icase[n])
      ylines, ystack = get_stackdata(spc,icase[n][i],output["specs"],unit[n])
      lt = make_plots.sel_ls(cs=colstyle[i], nc=1:length(ylines), nt=icase[n][i])
      fig = make_plots.plot_stack(output["time"],ylines,ystack,label[icase[n][i]],
                                  spc,unit[n],lt)
      pdffile[:savefig](fig)
    end  end
  else
    # Plot line plots of species concentrations and reaction rates for all cases
    for case in plotdata[n]
      fig = make_plots.lineplot(output["time"],output[what[n]],label,
                                what[n],unit[n],icase[n],case)
      pdffile[:savefig](fig)
    end
  end
end
# Close multipage pdf file
pdffile[:close]()


println("done.")

end #module DSMACCplot