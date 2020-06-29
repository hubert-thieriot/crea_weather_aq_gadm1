#' Deweathering function
#'
#' @param polls 
#' @param source 
#' @param country 
#' @param station_id 
#' @param city 
#' @param output either "anomaly", "trend" or both
#' @param aggregate_level "station" or "city"
#' @param upload_results T/F Whether to upload results or not
#' @param add_gadm1 T/F Whether to aggregate to GADM1 levels after computation
#' @param add_gadm2 T/F Whether to aggregate to GADM2 levels after computation
#'
#' @return
#' @export
#'
deweather <- function(
 polls=NULL,
 source=NULL,
 country=NULL,
 station_id=NULL,
 city=NULL,
 output="trend",
 aggregate_level="city",
 upload_results=T,
 add_gadm1=F,
 add_gadm2=F
){
  
  #----------------------
  # 0. Set parameters
  #----------------------
  training_start <- "2017-01-01"
  training_end_anomaly <- "2020-01-01"
  training_end_trend <- "2099-01-01"
  
  #----------------------
  # 1. Get measurements
  #----------------------
  print("1. Getting measurements")
  meas <- rcrea::measurements(poll=polls,
                              country=country,
                              location_id=station_id,
                              city=city,
                              aggregate_level=aggregate_level,
                              date_from=training_start,
                              source=source,
                              deweathered=F,
                              with_metadata=T,
                              with_geometry=T) %>%
    group_by(region_id, poll, unit, source, timezone, process_id, country, geometry) %>%
    tidyr::nest() %>%
    rename(station_id=region_id, meas=data) %>%
    ungroup()
  
  if(nrow(meas)==0){
    stop("No measurement found")
  }

  meas_sf <- meas %>%
    dplyr::ungroup() %>%
    dplyr::mutate(geometry=sf::st_centroid(geometry)) %>%
    sf::st_as_sf(sf_column_name="geometry", crs = 4326)

  #----------------------
  # 2. Add weather
  #----------------------
  print("2. Adding weather")
  meas_weather <- collect_weather(meas_sf,
                                  years=seq(lubridate::year(lubridate::date(training_start)), 2020),
                                  years_force_refresh=2020,
                                  add_pbl=F,
                                  add_sunshine=F,
                                  n_per_station=3
  )

  #----------------------
  # 3. Clean data
  #----------------------
  print("3. Cleaning data")
  data <- prep_data(meas_weather=meas_weather)
  
  #----------------------
  # 4. Train models
  #----------------------
  print("4. Training models")
  normalise <- F
  detect_breaks <- F
  trees <- 10000
  samples <- 100
  interaction.depth <- c(2)
  learning.rate <- c(0.01)
  lag <- 1
  engine <- "gbm"
  link <- "log"
  
  weather_vars <- c(list(c('air_temp_min','air_temp_max', 'atmos_pres', 'wd', 'ws_max', 'ceil_hgt', 'precip', 'RH_max')))
  
  time_vars_output <- tibble(
    time_vars=c(list(c('yday')),list(c('trend'))),
    output=c('anomaly','trend'),
    training_end=c(training_end_anomaly, training_end_trend)
    ) %>%
    filter(output %in% !!output)
  
  configs <-  tibble() %>%
    tidyr::expand(trees, lag, weather_vars, time_vars_output, engine, link, learning.rate, interaction.depth) %>%
    rowwise() %>%
    mutate(process_deweather=
             gsub("'","\"",paste0("{",
                                  "'engine':'",engine,"',",
                                  "'trees':'",trees,"',",
                                  "'learning.rate':'",learning.rate,"',",
                                  "'interaction.depth':'",interaction.depth,"',",
                                  "'lag':'",lag,"',",
                                  "'training_start':'",training_start,"',",
                                  "'training_end':'",training_end,"',",
                                  "'time_vars':['",paste0(time_vars,collapse="','"),"'],",
                                  "'weather_vars':['",paste0(weather_vars,collapse="','"),"'],",
                                  "'link':'",link,"',",
                                  "'output':'",output,"'",
                                  "}")
             )
    )
  
  results_nested <- configs %>%
    rowwise() %>%
    mutate(
      result=list(train_models(
        engine=engine,
        meas_weather=tibble(data),
        weather_vars=weather_vars,
        time_vars=time_vars,
        trees=trees,
        samples=samples,
        interaction.depth=interaction.depth,
        learning.rate=learning.rate,
        lag=lag,
        link=link,
        normalise=normalise,
        detect_breaks=detect_breaks,
        training_date_cut=training_end,
        save_result=F,
        return_result=T)
      )) %>%
    rowwise() %>%
    filter(any(!is.na(result)))
  
  if(nrow(results_nested)==0){
    warnings("Empty results. Returning NA")
    return(NA)
  }
  
  #--------------------------------------
  # 5. Post-compute / aggregate results
  #--------------------------------------
  results_anomaly <- NULL
  results_trend <- NULL
  
  if("anomaly" %in% output){
    results_anomaly <- results_nested %>% dplyr::filter(output=='anomaly') %>% tidyr::unnest(cols=c(result))  
    results_anomaly <- results_anomaly  %>% rowwise()  %>%
      dplyr::mutate(normalised=list(predicted %>%
                                      filter(set=='testing') %>%
                                      mutate(value=value-predicted)), # Not residuals but ANOMALY (i.e. -1 * residuals)
                    unit=paste('Δ', unit) # To force ploting on different charts on Dashboard
                    ) %>%
      dplyr::rename(region_id=station_id) %>%
      dplyr::select(process_id, process_deweather, normalised, poll, unit, region_id, source)  
  }
  
  if("trend" %in% output){
    results_trend <- results_nested %>% dplyr::filter(output=='trend') %>% tidyr::unnest(cols=c(result))
    results_trend <- results_trend  %>% rowwise()  %>%
      dplyr::mutate(normalised=list(trend)) %>%
      dplyr::rename(region_id=station_id) %>%
      dplyr::select(process_id, process_deweather, normalised, poll, unit, region_id, source)
  }

  
  results <- dplyr::bind_rows(
    results_trend,
    results_anomaly
  )  
 
  
  # Group by GADM2 and GADM1
  # results_anomaly_gadm1
  # process_id replace city->gadm
  locs <- rcrea::locations(source=source, with_meta = T) %>% mutate(city=tolower(city))
  agg_gadm1 <- function(results, locs){
    results %>%
      dplyr::left_join(locs %>% dplyr::select(city, gid_1), by=c("region_id"="city")) %>%
      dplyr::mutate(process_id=gsub("city","gadm1",process_id)) %>%
      tidyr::unnest(cols=normalised) %>%
      dplyr::group_by(process_id, process_deweather, poll, unit, source, gid_1, date) %>%
      dplyr::summarise(value=mean(value, na.rm=T)) %>%
      tidyr::nest() %>%
      rename(region_id=gid_1, normalised=data)
  }

  agg_gadm2 <- function(results, locs){
    results %>%
      left_join(locs %>% dplyr::select(city, gid_1, gid_2), by=c("region_id"="city")) %>%
      mutate(process_id=gsub("city","gadm2",process_id)) %>%
      tidyr::unnest(cols=normalised) %>%
      group_by(process_id, process_deweather, poll, unit, source, gid_2, date) %>%
      summarise(value=mean(value, na.rm=T)) %>%
      tidyr::nest() %>%
      rename(region_id=gid_2, normalised=data)
  }
  
  if(add_gadm1){
    results_gadm1 <- agg_gadm1(results, locs)
  }
  
  if(add_gadm2){
    results_gadm2 <- agg_gadm2(results, locs)
  }
  
  #--------------------
  # 6. Upload results
  #--------------------
  if(upload_results){
    
    processes <- results %>% distinct(process_id, process_deweather)
    
    results_uploaded <- results %>%
      rowwise() %>%
      mutate(deweather_process_id=upload_process_meas(process_id, process_deweather, poll, unit, region_id, normalised, source, paste0(output,"_gbm_lag",lag,"_",aggregate_level)))
    
    if(add_gadm1){
      results_gadm1_uploaded <- results_gadm1 %>%
        rowwise() %>%
        mutate(deweather_process_id=upload_process_meas(process_id, process_deweather, poll, unit, region_id, normalised, source, paste0(output,"_gbm_lag",lag,"_gadm1",)))
      results_uploaded <- rbind(
        results_uploaded,
        results_anomaly_gadm1_uploaded)
    }
    
    if(add_gadm2){
      results_gadm2_uploaded <- results_gadm2 %>%
        rowwise() %>%
        mutate(deweather_process_id=upload_process_meas(process_id, process_deweather, poll, unit, region_id, normalised, source, paste0(output,"_gbm_lag",lag,"_gadm2",)))
      results_uploaded <- rbind(
        results_uploaded,
        results_anomaly_gadm2_uploaded)
    }
    return(results_uploaded)
  }else{
    return(results)
  }
}
