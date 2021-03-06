# Download and install PRISM data into PostgreSQL and values for BBS routes

options(prism.path = "./data/prismdata")

#Years of prism data to
years_to_use=1981:2014

#######################################################
#Downloads the raw prism rasters into the folder specified above.
#######################################################
#' @importFrom prism get_prism_monthlys ls_prism_data prism_stack
download_prism=function(){
  months <- c(1:12)
  clim_vars <- c("ppt", "tmin", "tmean", "tmax")
  for (month in months){
    for (clim_var in clim_vars){
      get_prism_monthlys(type=clim_var, year = years_to_use, mon = month, keepZip=F)
    }
  }
}


########################################################
#Takes output of ls_prism_data() and makes sure all files
#within a year range are there. ie. for all 12 months and
#all 4 variables.
#########################################################
#' @importFrom dplyr %>% arrange filter mutate rowwise collect copy_to sql src_tbls tbl full_join group_by left_join summarize ungroup
check_if_prism_files_present=function(prism_ls, years){
  #Extract out all the variable names and dates
  if (length(prism_ls$files) == 0){return(FALSE)}
  prism_ls = prism_ls %>%
    rowwise() %>%
    mutate(var=strsplit(files, '_')[[1]][2], yearMonth=strsplit(files, '_')[[1]][5]) %>%
    mutate(year=as.integer(substr(yearMonth,1,4)), month=as.integer(substr(yearMonth, 5,6))) %>%
    dplyr::select(-files, -yearMonth) %>%
    filter(year %in% years) %>%
    arrange(var, year, month)

  #Setup a list of what should be there
  to_check=expand.grid(var=c('ppt','tmax','tmean','tmin'), year=years, month=1:12, stringsAsFactors = FALSE) %>%
    arrange(var,year,month)

  #If these two data frames are equal, then all prism raster data in the years specified is present.
  #all.equal returns TRUE if they are equal, and a description of the discrepency if they are not equal,
  #hence the isTRUE wrapper.
  return(isTRUE(base::all.equal(to_check, prism_ls, check.attributes=FALSE)))
}

########################################################
#Return prism data for each site from the sqlite DB. If it's not loaded in
#the DB, then extract values from the raw prism rasters, store in DB, and return them.
########################################################
#' @importFrom tidyr gather spread
#' @importFrom dplyr "%>%" distinct
#' @importFrom sp coordinates
get_prism_data=function(){
  #Query sqlite database for the prism_bbs_data table. If it exists, return it.
  #Otherwise create it from the raw prism data.
  if(db_engine(action='check', table_to_check = 'prism_bbs_data')){
    return(db_engine(action = 'read', sql_query='SELECT * from prism_bbs_data'))
  } else {
    print('PRISM data table not found, processing raw data')

    bbs_data <- get_bbs_data()
    locations <- dplyr::select(bbs_data, site_id, long, lat) %>%
      distinct()
    coordinates(locations) <- c("long", "lat")
    raster::crs(locations) <- '+proj=longlat +datum=NAD83 +no_defs +ellps=GRS80 +towgs84=0,0,0'
    
    #Check to see if all the raw data in the years specified are downloaded,
    #download everything again if not. (Getting only what is needed, say if a
    #previous download failed, might be overly complicated)
    if(!check_if_prism_files_present(ls_prism_data(), years_to_use)){
      download_prism()
    }

    #Load the prism data and extract using the bbs locations.
    prism_stacked <- prism_stack(ls_prism_data())
    #Aggregate to 40km. Original cells average ~4.5 across N. America,
    #so aggregation of 9x9 creates mostly 40km cells. 
    prism_stacked = raster::aggregate(prism_stacked, fact=9)
    save_provenance(prism_stacked)
    extracted <- raster::extract(prism_stacked, locations)
    prism_bbs_data <- data.frame(site_id = locations$site_id, coordinates(locations), extracted)
    prism_bbs_data <- prism_bbs_data %>%
      gather(date, value, 4:ncol(prism_bbs_data)) %>%
      tidyr::extract(date, c("clim_var", "year", "month"),
                     "PRISM_([:alpha:]*)_stable_[:alnum:]*_([:digit:]{4})([:digit:]{2})_")

    #Format the data a little and load into the sqlite database.
    prism_bbs_data$year <- as.numeric(prism_bbs_data$year)
    prism_bbs_data$month <- as.numeric(prism_bbs_data$month)

    db_engine(action='write', df=prism_bbs_data, new_table_name = 'prism_bbs_data')

    #Now return the data as asked for
    return(prism_bbs_data)

  }
}

########################################################
#Extract route data from a single cmip file, returning a data.frame
########################################################
extract_cmip_data=function(cmip_filename, clim_var){
  cmip_raster = raster::stack(cmip_filename)

  #Missing values from water bodies are set as NaN but need to be NA
  #for the aggregation step, otherwise missing values propagate along
  #coasts. 
  cmip_raster[is.nan(cmip_raster)] = NA
  
  #Aggregate the 12km cell size close to 40km
  cmip_raster = raster::aggregate(cmip_raster, fact=3, fun=mean)

  route_locations = get_route_data()

  extracted = raster::extract(cmip_raster, route_locations)

  cmip_df = data.frame(site_id = route_locations$site_id, extracted) %>%
    gather(date_string, value, -site_id) %>%
    mutate(year=as.numeric(substr(date_string, 2,5)),
           month=as.numeric(substr(date_string, 7,8))) %>%
    select(-date_string)

  cmip_df$clim_var = clim_var

  return(cmip_df)
}

########################################################
#Return cmip5 data from 2010-2050 for each site from the sqlite DB.
########################################################
get_cmip5_data=function(){
  if(db_engine(action='check', table_to_check = 'cmip5_bbs_data')){
    return(db_engine(action = 'read', sql_query='SELECT * from cmip5_bbs_data'))
  } else {
    print('CMIP5 data table not found, processing raw data')

    files = c('./data/cmip5/cmip5_ppt.nc', './data/cmip5/cmip5_tmean.nc',
              './data/cmip5/cmip5_tmax.nc', './data/cmip5/cmip5_tmin.nc')
    clim_vars = c('ppt','tmean',
                  'tmax','tmin')

    for(f in files){
      if(!file.exists(f)){stop(paste0('CMIP file not present. Need to download data and/or run process_bcsd_data.py: ',f))}
    }

    cmip_data = purrr::map2_df(files, clim_vars, extract_cmip_data)

    db_engine(action='write', df=cmip_data, new_table_name = 'cmip5_bbs_data')

    return(cmip_data)
  }
}


###################################################################
#Helper function to calculate some of the bioclim variables,
#like "precip in coldest month"
###################################################################
max_min_combo=function(vec1,vec2,max=TRUE){
  #Return the value in vec1 in the position where
  #vec2 is either highest or lowest. But 1st check for na
  #values.
  if(any(is.na(vec1)) | any(is.na(vec2))){
    return(NA)
  } else  if(max){
    return(vec1[which.max(vec2)])
  } else {
    return(vec1[which.min(vec2)])
  }
}

#################################################################
#From raw monthly climate values calculate all the bioclim variables.
#You should not call this directly to load bioclim vars. Instead call
#get_bioclim_data(), which will 1st try to load the data from the sqlite
#db before processing it all from scratch.
#Columns present must be c('year','month','value','clim_var','site_id')
###################################################################
#' @importFrom raster cv
#' @importFrom dplyr "%>%" left_join group_by summarise ungroup mutate full_join
#' @importFrom tidyr spread
process_bioclim_data=function(monthly_climate_data){

  #Offset the year by 6 months so that the window for calculating bioclim variables
  #will be July 1 - June 30. See https://github.com/weecology/bbs-forecasting/issues/114
  monthly_climate_data$year = with(monthly_climate_data, ifelse(month %in% 7:12, year+1, year))
  
  #Spread out the climate variables ppt, tmean, etc into columns
  monthly_climate_data = monthly_climate_data %>%
    spread(clim_var, value)

  #Process the quarter ones first.
  quarter_info=data.frame(month=1:12, quarter=c(3,3,3,4,4,4,1,1,1,2,2,2))
  bioclim_quarter_data= monthly_climate_data %>%
    left_join(quarter_info, by='month') %>%
    group_by(site_id, year, quarter) %>%
    summarise(precip=sum(ppt), temp=mean(tmean)) %>%
    ungroup() %>%
    group_by(site_id,year) %>%
    summarise(bio8=max_min_combo(temp, precip, max=TRUE),
              bio9=max_min_combo(temp, precip, max=FALSE),
              bio10=max(temp),
              bio11=min(temp),
              bio16=max(precip),
              bio17=min(precip),
              bio18=max_min_combo(precip, temp, max=TRUE),
              bio19=max_min_combo(precip, temp, max=FALSE)) %>%
    ungroup()

  #Next the yearly ones, joining the quartely ones  back in at the end.
  bioclim_data=monthly_climate_data %>%
    group_by(site_id, year) %>%
    mutate(monthly_temp_diff=tmax-tmin) %>%
    summarise(bio1=mean(tmean),
              bio2=mean(monthly_temp_diff),
              bio4=sd(tmean)*100,
              bio5=max_min_combo(tmax,tmean,max=TRUE),
              bio6=max_min_combo(tmin,tmean,max=FALSE),
              bio12=sum(ppt),
              bio13=max(ppt),
              bio14=min(ppt),
              bio15=cv(ppt)) %>%
    ungroup() %>%
    mutate(bio7=bio5-bio6,
           bio3=(bio2/bio7)*100) %>%
    full_join(bioclim_quarter_data, by=c('site_id','year'))

  return(bioclim_data)
}


####################################################################
#Load the bioclim variables from sqlite. if they aren't available,
#load the prism data, process bioclim, load it in sqlite, then return
#bioclim as requested.
#
#TODO: Possibly put a check here to make sure all years are accounted for?
####################################################################

get_bioclim_data=function(source='prism'){
  if(source=='prism'){
    if(db_engine(action='check', table_to_check = 'bioclim_prism_bbs_data')){
      return(db_engine(action = 'read', sql_query='SELECT * from bioclim_prism_bbs_data'))
    } else {
      print("bioclim_prism data table not found, processing from scratch. ")
      bioclim_bbs_data=process_bioclim_data(get_prism_data())

      db_engine(action='write', df=bioclim_bbs_data, new_table_name = 'bioclim_prism_bbs_data')

      return(bioclim_bbs_data)

    }
  }
  else if(source=='cmip5'){
    if(db_engine(action='check', table_to_check = 'bioclim_cmip5_bbs_data')){
      return(db_engine(action = 'read', sql_query='SELECT * from bioclim_cmip5_bbs_data'))
    } else {
      print("bioclim_cmip5 data table not found, processing from scratch. ")
      bioclim_bbs_data=process_bioclim_data(get_cmip5_data())

      db_engine(action='write', df=bioclim_bbs_data, new_table_name = 'bioclim_cmip5_bbs_data')

      return(bioclim_bbs_data)
    }
  } else {
    stop(paste('bioclim data source uknown:',source))
  }
}
